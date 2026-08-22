//! A parse-free pre-scan that decides whether a file can contain a finding.

const std = @import("std");
const gostd = @import("gostd.zig");
const gopath = @import("gopath.zig");
const normalize = @import("normalize.zig");
const extract = @import("extract.zig");

/// Reports whether `content` may contain a literal whose normalized form
/// satisfies `worth`. It scans the raw bytes for a lexical superset of every
/// literal value the extractor can produce, without parsing:
///
///   - every string literal's value is the text between two consecutive
///     unescaped quotes of the same kind, because a string cannot contain an
///     unescaped copy of its own quote;
///   - every substitution-free template literal's value is likewise the text
///     between consecutive unescaped backticks;
///   - every JSX text node's value is a maximal run of bytes containing none of
///     '<', '>', '{', '}', because those characters delimit JSX text.
///
/// Extra candidates produced from code between real literals can only cause a
/// false positive, which the caller resolves with a full parse. A false result
/// therefore guarantees that a full parse would yield no matching literals,
/// letting callers skip tree-sitter entirely for clean files.
pub fn hasCandidateMatch(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    min_length: usize,
    worth: extract.MatchFunc,
) !bool {
    if (try scanQuoteSpans(allocator, content, '\'', min_length, worth)) return true;
    if (try scanQuoteSpans(allocator, content, '"', min_length, worth)) return true;
    if (try scanQuoteSpans(allocator, content, '`', min_length, worth)) return true;
    // Plain .ts files are parsed with the JSX-free TypeScript grammar, so they
    // can never produce JSX text literals.
    if (!isPlainTypeScript(path) and try scanJSXTextRuns(allocator, content, min_length, worth)) return true;
    return false;
}

fn isPlainTypeScript(path: []const u8) bool {
    const extension = gopath.ext(path);
    if (extension.len != 3) return false;
    return gostd.toLower(extension[0]) == '.' and
        gostd.toLower(extension[1]) == 't' and
        gostd.toLower(extension[2]) == 's';
}

/// Feeds every span between consecutive unescaped quote bytes through the
/// candidate check. Treating each quote as a potential opener keeps the scan a
/// superset of real string literals regardless of which quotes actually open
/// strings: junk spans between literals simply fail the index lookup.
fn scanQuoteSpans(
    allocator: std.mem.Allocator,
    content: []const u8,
    quote: u8,
    min_length: usize,
    worth: extract.MatchFunc,
) !bool {
    var previous: ?usize = null;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const offset = std.mem.indexOfScalar(u8, content[i..], quote) orelse return false;
        i += offset;
        // Escapedness is decided by backslash parity.
        var backslashes: usize = 0;
        var j = i;
        while (j > 0 and content[j - 1] == '\\') : (j -= 1) backslashes += 1;
        if (backslashes % 2 == 1) continue;
        if (previous) |start| {
            if (try checkQuotedCandidate(allocator, content[start + 1 .. i], quote, min_length, worth)) return true;
        }
        previous = i;
    }
    return false;
}

fn checkQuotedCandidate(
    allocator: std.mem.Allocator,
    raw: []const u8,
    quote: u8,
    min_length: usize,
    worth: extract.MatchFunc,
) !bool {
    // A template containing an unescaped substitution never yields a literal.
    if (quote == '`' and hasUnescapedSubstitution(raw)) return false;
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
        return checkCandidateBytes(allocator, raw, min_length, worth);
    }
    const unquoted = try extract.unquoteJS(allocator, raw, quote);
    // unquoteJS hands back the input untouched when nothing needed decoding.
    defer if (unquoted.ptr != raw.ptr) allocator.free(unquoted);
    return checkCandidate(allocator, unquoted, min_length, worth);
}

fn hasUnescapedSubstitution(raw: []const u8) bool {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        switch (raw[i]) {
            '\\' => i += 1,
            '$' => if (i + 1 < raw.len and raw[i + 1] == '{') return true,
            else => {},
        }
    }
    return false;
}

/// Feeds every maximal run of bytes without JSX structure characters through
/// the candidate check. Real JSX text nodes are exactly such runs; runs of
/// ordinary code are junk candidates that fail the lookup.
fn scanJSXTextRuns(
    allocator: std.mem.Allocator,
    content: []const u8,
    min_length: usize,
    worth: extract.MatchFunc,
) !bool {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i < content.len) {
            switch (content[i]) {
                '<', '>', '{', '}' => {},
                else => continue,
            }
        }
        const run = content[start..i];
        start = i + 1;
        if (try checkCandidateBytes(allocator, run, min_length, worth)) return true;
    }
    return false;
}

/// Applies the same length gate and normalization as the extractor before
/// consulting the worth filter.
fn checkCandidate(
    allocator: std.mem.Allocator,
    value: []const u8,
    min_length: usize,
    worth: extract.MatchFunc,
) !bool {
    const collapsed = try normalize.collapseWhitespace(allocator, value);
    defer allocator.free(collapsed);
    if (normalize.gateLength(collapsed) < min_length) return false;
    const normalized = try gostd.toLowerString(allocator, collapsed);
    defer allocator.free(normalized);
    if (normalized.len == 0) return false;
    return worth.worth(normalized);
}

// Byte classes for the fast candidate gate below.
const ByteClass = enum(u8) {
    plain,
    space,
    /// Whitespace that is not ' ', so collapsing changes it.
    newline_space,
    upper,
    /// Non-ASCII: fall back to the rune-correct path.
    high,
};

const byte_classes = blk: {
    var classes: [256]ByteClass = @splat(.plain);
    for ([_]u8{ '\t', '\n', 0x0B, 0x0C, '\r' }) |b| classes[b] = .newline_space;
    classes[' '] = .space;
    for ('A'..'Z' + 1) |b| classes[b] = .upper;
    for (0x80..0x100) |b| classes[b] = .high;
    break :blk classes;
};

/// checkCandidate for raw byte spans. For ASCII input it computes the length
/// gate without allocating, so the frequent junk spans between real literals
/// cost nothing; the normalized string is only built for spans that pass.
fn checkCandidateBytes(
    allocator: std.mem.Allocator,
    raw: []const u8,
    min_length: usize,
    worth: extract.MatchFunc,
) !bool {
    // The gate below counts each collapsed span at most twice its byte length,
    // so spans shorter than half min_length can never pass.
    if (2 * raw.len < min_length) return false;

    // Single ASCII pass mirroring collapseWhitespace plus the extractor's
    // length gate: collapsed length plus one extra count per collapsed space.
    var gate: usize = 0;
    var spaces: usize = 0;
    var pending_space = false;
    var changed = false;
    for (raw) |b| {
        switch (byte_classes[b]) {
            .plain => {},
            .space => {
                if (pending_space or gate == 0) changed = true;
                pending_space = gate > 0;
                continue;
            },
            .newline_space => {
                changed = true;
                pending_space = gate > 0;
                continue;
            },
            .upper => changed = true,
            .high => return checkCandidate(allocator, raw, min_length, worth),
        }
        if (pending_space) {
            gate += 2;
            spaces += 1;
            pending_space = false;
        }
        gate += 1;
    }
    if (pending_space) changed = true;
    if (gate < min_length or gate == 0) return false;
    if (!changed) return worth.worth(raw);

    const normalized = try allocator.alloc(u8, gate - spaces);
    defer allocator.free(normalized);
    var n: usize = 0;
    pending_space = false;
    for (raw) |b| {
        const class = byte_classes[b];
        if (class == .space or class == .newline_space) {
            pending_space = n > 0;
            continue;
        }
        if (pending_space) {
            normalized[n] = ' ';
            n += 1;
            pending_space = false;
        }
        normalized[n] = if (b >= 'A' and b <= 'Z') b + ('a' - 'A') else b;
        n += 1;
    }
    return worth.worth(normalized[0..n]);
}
