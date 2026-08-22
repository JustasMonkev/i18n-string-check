//! The translation index: exact values, interpolation/plural patterns, and the
//! similarity structures behind `--similarity-flow`.

const std = @import("std");
const gostd = @import("gostd.zig");
const jsonutil = @import("jsonutil.zig");
const normalize = @import("normalize.zig");

/// Explains why a pattern or similarity lookup reported a match.
pub const Detail = struct {
    reason: []const u8 = "",
    score: f64 = 0,
    why: []const u8 = "",
};

pub const Match = struct {
    key: []const u8,
    value: []const u8,
    normalized_value: []const u8 = "",
    detail: Detail = .{},
};

/// Similarity matching data: tokens interned to dense ids and an inverted
/// index from token id to eligible entries. Word overlap is computed by
/// counting posting hits per candidate instead of intersecting per-entry word
/// sets, so a lookup never iterates or hashes candidate word sets.
const SimIndex = struct {
    /// Aligned with Index.all; token_count is zero for entries that are not
    /// similarity candidates.
    entries_meta: []EntryMeta = &.{},
    vocab: std.StringHashMapUnmanaged(u32) = .empty,
    /// Maps a token id to the similarity-eligible entries containing that
    /// token. Candidate discovery only walks tokens of length >= 3; shorter
    /// tokens are indexed so overlap counts stay exact.
    postings: [][]u32 = &.{},

    const EntryMeta = struct { rune_count: u32 = 0, token_count: u32 = 0 };
};

/// Reusable per-query state. `counts` is indexed by entry: 0 untouched, -1
/// rejected by the length filter, otherwise the number of shared tokens so
/// far. `touched` lists the entries to reset after the query.
pub const SimScratch = struct {
    allocator: std.mem.Allocator,
    counts: []i32 = &.{},
    token_seen: []u32 = &.{},
    touched: std.ArrayList(u32) = .empty,
    long_ids: std.ArrayList(u32) = .empty,
    short_ids: std.ArrayList(u32) = .empty,
    unknown: std.ArrayList([]const u8) = .empty,
    unique: std.StringHashMapUnmanaged(void) = .empty,
    epoch: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, index: *const Index) !SimScratch {
        const counts = try allocator.alloc(i32, index.all.len);
        @memset(counts, 0);
        const token_seen = try allocator.alloc(u32, index.sim.postings.len);
        @memset(token_seen, 0);
        return .{ .allocator = allocator, .counts = counts, .token_seen = token_seen };
    }

    pub fn deinit(self: *SimScratch) void {
        self.allocator.free(self.counts);
        self.allocator.free(self.token_seen);
        self.touched.deinit(self.allocator);
        self.long_ids.deinit(self.allocator);
        self.short_ids.deinit(self.allocator);
        self.unknown.deinit(self.allocator);
        self.unique.deinit(self.allocator);
    }
};

/// One element of a compiled translation pattern. Translation patterns only
/// ever need literal runs, `{placeholder}` and ICU's `#`, so a tiny matcher
/// replaces a full regex engine.
const PatternElem = union(enum) {
    /// Matched byte-for-byte.
    literal: []const u8,
    /// One or more characters, never a newline (Go's `.+` without the `s` flag).
    any_plus,
    /// One or more ASCII digits (Go's `\d+`).
    digits_plus,
};

const PatternMatch = struct {
    match: Match,
    elems: []const PatternElem,
    /// The literal text before the first placeholder, used to skip the matcher
    /// for the common non-matching case.
    prefix: []const u8,
};

pub const Index = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged([]Match) = .empty,
    patterns: []PatternMatch = &.{},
    /// Widest compiled pattern, used to size the matcher's memo buffer once
    /// per lookup rather than once per pattern.
    max_pattern_elems: usize = 0,
    all: []Match = &.{},
    sim: SimIndex = .{},

    pub fn deinit(self: *Index) void {
        self.arena.deinit();
    }

    pub fn len(self: *const Index) usize {
        return self.entries.count();
    }

    /// Exact lookup by normalized value. The returned slice is owned by the
    /// index and must not be mutated.
    pub fn lookupNormalized(self: *const Index, normalized: []const u8) []const Match {
        return self.entries.get(normalized) orelse &.{};
    }

    /// Interpolation and plural patterns whose shape the literal fills in.
    ///
    /// `allocator` owns the returned matches; `scratch` holds only the
    /// matcher's memo buffer and is released before returning, so it can be a
    /// short-lived allocator even when the results are long-lived.
    pub fn lookupPatternNormalized(
        self: *const Index,
        allocator: std.mem.Allocator,
        scratch: std.mem.Allocator,
        normalized: []const u8,
    ) ![]Match {
        var matches: std.ArrayList(Match) = .empty;
        errdefer matches.deinit(allocator);
        if (self.patterns.len == 0) return matches.toOwnedSlice(allocator);

        const width = normalized.len + 1;
        const memo = try scratch.alloc(bool, self.max_pattern_elems * width);
        defer scratch.free(memo);

        for (self.patterns) |candidate| {
            if (candidate.prefix.len > 0 and !std.mem.startsWith(u8, normalized, candidate.prefix)) continue;
            if (!matchPattern(candidate.elems, normalized, memo, width)) continue;
            var match = candidate.match;
            match.detail = .{
                .reason = "translation-pattern",
                .score = 1,
                .why = "source string matches the current translation pattern",
            };
            try matches.append(allocator, match);
        }
        return matches.toOwnedSlice(allocator);
    }

    /// Whether any pattern matches, without materialising the match list. The
    /// pre-scan asks this for every candidate span and discards the answer's
    /// detail, so building those matches would be pure waste.
    pub fn matchesAnyPattern(
        self: *const Index,
        scratch: std.mem.Allocator,
        normalized: []const u8,
    ) !bool {
        if (self.patterns.len == 0) return false;
        const width = normalized.len + 1;
        const memo = try scratch.alloc(bool, self.max_pattern_elems * width);
        defer scratch.free(memo);
        for (self.patterns) |candidate| {
            if (candidate.prefix.len > 0 and !std.mem.startsWith(u8, normalized, candidate.prefix)) continue;
            if (matchPattern(candidate.elems, normalized, memo, width)) return true;
        }
        return false;
    }

    /// Conservative similarity matching, capped at the three best candidates.
    pub fn lookupSimilarNormalized(
        self: *const Index,
        allocator: std.mem.Allocator,
        transient: std.mem.Allocator,
        scratch: *SimScratch,
        normalized: []const u8,
    ) ![]Match {
        const query = similarityEligible(normalized) orelse return &.{};

        try self.collectQueryTokens(scratch, normalized);
        // Without a shared token of length >= 3 there can be no candidates, so
        // most non-translation strings stop here before any counting work.
        if (scratch.long_ids.items.len == 0) return &.{};
        const query_tokens = scratch.long_ids.items.len +
            scratch.short_ids.items.len +
            try countUnique(scratch, scratch.unknown.items);

        // Discovery walks the postings of tokens with length >= 3, counting
        // shared tokens per entry; the length-ratio filter runs once per entry
        // on first touch. Short-token postings then top up the counts of
        // already discovered candidates so overlap ratios match full word-set
        // intersection.
        for (scratch.long_ids.items) |id| {
            for (self.sim.postings[id]) |entry| {
                const count = scratch.counts[entry];
                if (count > 0) {
                    scratch.counts[entry] = count + 1;
                } else if (count == 0) {
                    scratch.counts[entry] = if (likelySimilarLength(query.rune_count, self.sim.entries_meta[entry].rune_count)) 1 else -1;
                    try scratch.touched.append(scratch.allocator, entry);
                }
            }
        }
        for (scratch.short_ids.items) |id| {
            for (self.sim.postings[id]) |entry| {
                if (scratch.counts[entry] > 0) scratch.counts[entry] += 1;
            }
        }

        var matches: std.ArrayList(Match) = .empty;
        errdefer matches.deinit(allocator);
        for (scratch.touched.items) |entry| {
            const shared = scratch.counts[entry];
            scratch.counts[entry] = 0;
            if (shared <= 0) continue;
            var match = self.all[entry];
            if (std.mem.eql(u8, normalized, match.normalized_value)) continue;
            const meta = self.sim.entries_meta[entry];
            const denominator: f64 = @floatFromInt(@max(meta.token_count, query_tokens));
            const overlap = @as(f64, @floatFromInt(shared)) / denominator;
            if (try similarityDetails(allocator, transient, normalized, query.rune_count, match.normalized_value, meta.rune_count, overlap)) |detail| {
                match.detail = detail;
                try matches.append(allocator, match);
            }
        }
        scratch.touched.clearRetainingCapacity();

        const result = try matches.toOwnedSlice(allocator);
        std.mem.sort(Match, result, {}, struct {
            fn lessThan(_: void, a: Match, b: Match) bool {
                if (a.detail.score != b.detail.score) return a.detail.score > b.detail.score;
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.lessThan);
        if (result.len > 3) {
            defer allocator.free(result);
            return allocator.dupe(Match, result[0..3]);
        }
        return result;
    }

    /// Splits the query into the tokens wordSet would produce. Tokens known to
    /// the index vocabulary are deduplicated into long/short id lists (split at
    /// the 3-byte candidate-discovery cutoff); unknown tokens are stashed
    /// separately, still with duplicates, for the overlap denominator count.
    fn collectQueryTokens(self: *const Index, scratch: *SimScratch, normalized: []const u8) !void {
        scratch.epoch +%= 1;
        scratch.long_ids.clearRetainingCapacity();
        scratch.short_ids.clearRetainingCapacity();
        scratch.unknown.clearRetainingCapacity();

        var start: ?usize = null;
        var it = gostd.runes(normalized);
        while (it.next()) |item| {
            if (gostd.isLetter(item.value) or gostd.isDigit(item.value)) {
                if (start == null) start = item.index;
                continue;
            }
            if (start) |s| {
                try self.appendQueryToken(scratch, normalized[s..item.index]);
                start = null;
            }
        }
        if (start) |s| try self.appendQueryToken(scratch, normalized[s..]);
    }

    fn appendQueryToken(self: *const Index, scratch: *SimScratch, token: []const u8) !void {
        if (self.sim.vocab.get(token)) |id| {
            if (scratch.token_seen[id] == scratch.epoch) return;
            scratch.token_seen[id] = scratch.epoch;
            if (token.len >= 3) {
                try scratch.long_ids.append(scratch.allocator, id);
            } else {
                try scratch.short_ids.append(scratch.allocator, id);
            }
            return;
        }
        try scratch.unknown.append(scratch.allocator, token);
    }
};

/// Counts distinct strings in linear time. Query tokens come from source files
/// and can be attacker-controlled, so avoid nested scans that let large
/// literals force quadratic work during similarity pre-scans.
fn countUnique(scratch: *SimScratch, tokens: []const []const u8) !usize {
    if (tokens.len == 0) return 0;
    scratch.unique.clearRetainingCapacity();
    try scratch.unique.ensureTotalCapacity(scratch.allocator, @intCast(tokens.len));
    for (tokens) |token| scratch.unique.putAssumeCapacity(token, {});
    return scratch.unique.count();
}

fn likelySimilarLength(a_len: u32, b_len: u32) bool {
    if (a_len == 0 or b_len == 0) return false;
    const shorter = @min(a_len, b_len);
    const longer = @max(a_len, b_len);
    // Integer form of shorter/longer >= 0.5, avoiding the division.
    return 2 * shorter >= longer;
}

pub fn hasExactValue(matches: []const Match, value: []const u8) bool {
    for (matches) |match| {
        if (std.mem.eql(u8, match.value, value)) return true;
    }
    return false;
}

// -- construction ------------------------------------------------------------

pub const LoadError = error{MalformedTranslations} || std.mem.Allocator.Error;

pub fn fromBytes(allocator: std.mem.Allocator, content: []const u8, min_length: usize) LoadError!*Index {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var flat: std.ArrayList(Entry) = .empty;
    {
        var parsed = jsonutil.parse(allocator, content) catch {
            return error.MalformedTranslations;
        };
        defer parsed.deinit();
        switch (parsed.value) {
            .object => |obj| try flattenTranslations(a, "", obj, &flat),
            // Go unmarshals into map[string]string; only an object or null fits.
            .null => {},
            else => return error.MalformedTranslations,
        }
    }
    // Go ranges over a map here, so its entry order — and therefore the order
    // of the keys reported for a value shared by several keys — varies between
    // runs. Sorting makes that output stable.
    std.mem.sort(Entry, flat.items, {}, Entry.lessThan);

    var builder = Builder{ .arena = &arena, .index = try a.create(Index) };
    builder.index.* = .{ .arena = undefined };
    for (flat.items) |entry| {
        const trimmed = try normalize.trimmedLength(a, entry.value);
        if (trimmed < min_length) continue;
        try builder.add(entry.key, entry.value);
    }
    try builder.finish();

    const index = builder.index;
    index.arena = arena;
    return index;
}

const Entry = struct {
    key: []const u8,
    value: []const u8,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.key, b.key) == .lt;
    }
};

fn flattenTranslations(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    obj: std.json.ObjectMap,
    flat: *std.ArrayList(Entry),
) !void {
    var it = obj.iterator();
    while (it.next()) |kv| {
        const path = if (prefix.len == 0)
            try allocator.dupe(u8, kv.key_ptr.*)
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, kv.key_ptr.* });
        switch (kv.value_ptr.*) {
            .string => |s| try flat.append(allocator, .{ .key = path, .value = try allocator.dupe(u8, s) }),
            .object => |nested| try flattenTranslations(allocator, path, nested, flat),
            // Numbers, booleans, arrays and null are not translation values.
            else => continue,
        }
    }
}

const Builder = struct {
    arena: *std.heap.ArenaAllocator,
    index: *Index,
    all: std.ArrayList(Match) = .empty,
    patterns: std.ArrayList(PatternMatch) = .empty,
    entries_meta: std.ArrayList(SimIndex.EntryMeta) = .empty,
    postings: std.ArrayList(std.ArrayList(u32)) = .empty,

    fn add(self: *Builder, key: []const u8, value: []const u8) !void {
        const a = self.arena.allocator();
        const normalized = try normalize.normalize(a, value);
        const entry_index: u32 = @intCast(self.all.items.len);
        const match = Match{ .key = key, .value = value, .normalized_value = normalized };

        const gop = try self.index.entries.getOrPut(a, normalized);
        if (gop.found_existing) {
            const grown = try a.alloc(Match, gop.value_ptr.len + 1);
            @memcpy(grown[0..gop.value_ptr.len], gop.value_ptr.*);
            grown[gop.value_ptr.len] = match;
            gop.value_ptr.* = grown;
        } else {
            const single = try a.alloc(Match, 1);
            single[0] = match;
            gop.value_ptr.* = single;
        }
        try self.all.append(a, match);

        var meta = SimIndex.EntryMeta{};
        if (similarityEligible(normalized)) |stats| {
            var words: std.StringHashMapUnmanaged(void) = .empty;
            defer words.deinit(a);
            try wordSet(a, normalized, &words);
            meta = .{ .rune_count = stats.rune_count, .token_count = @intCast(words.count()) };
            var it = words.keyIterator();
            while (it.next()) |word| {
                const vocab = try self.index.sim.vocab.getOrPut(a, word.*);
                if (!vocab.found_existing) {
                    vocab.value_ptr.* = @intCast(self.postings.items.len);
                    try self.postings.append(a, .empty);
                }
                try self.postings.items[vocab.value_ptr.*].append(a, entry_index);
            }
        }
        try self.entries_meta.append(a, meta);

        var templates: std.ArrayList([]const u8) = .empty;
        defer templates.deinit(a);
        try translationPatternTemplates(a, value, &templates);
        for (templates.items) |template| {
            if (try compileTranslationPattern(a, template)) |compiled| {
                try self.patterns.append(a, .{
                    .match = match,
                    .elems = compiled.elems,
                    .prefix = compiled.prefix,
                });
            }
        }
    }

    fn finish(self: *Builder) !void {
        const a = self.arena.allocator();
        self.index.all = self.all.items;
        self.index.patterns = self.patterns.items;
        for (self.patterns.items) |pattern| {
            self.index.max_pattern_elems = @max(self.index.max_pattern_elems, pattern.elems.len);
        }
        self.index.sim.entries_meta = self.entries_meta.items;
        const postings = try a.alloc([]u32, self.postings.items.len);
        for (self.postings.items, 0..) |list, i| postings[i] = list.items;
        self.index.sim.postings = postings;
    }
};

// -- similarity --------------------------------------------------------------

const SimilarityStats = struct { rune_count: u32, field_count: u32 };

/// Reports whether a value is long enough for similarity matching (>= 24 runes
/// and >= 5 whitespace fields) and returns its rune count.
fn similarityEligible(value: []const u8) ?SimilarityStats {
    const stats = similarityStats(value);
    if (stats.rune_count < 24 or stats.field_count < 5) return null;
    return stats;
}

/// Counts runes and whitespace-separated fields in one pass. ASCII input, the
/// overwhelmingly common case, is handled byte-wise without rune decoding.
fn similarityStats(value: []const u8) SimilarityStats {
    var rune_count: u32 = 0;
    var count: u32 = 0;
    var in_field = false;
    for (value, 0..) |b, i| {
        if (b >= 0x80) return similarityStatsRunes(value[i..], rune_count, count, in_field);
        rune_count += 1;
        if (b == ' ' or (b >= '\t' and b <= '\r')) {
            in_field = false;
            continue;
        }
        if (!in_field) {
            in_field = true;
            count += 1;
        }
    }
    return .{ .rune_count = rune_count, .field_count = count };
}

fn similarityStatsRunes(rest: []const u8, rune_count_in: u32, count_in: u32, in_field_in: bool) SimilarityStats {
    var rune_count = rune_count_in;
    var count = count_in;
    var in_field = in_field_in;
    var it = gostd.runes(rest);
    while (it.next()) |item| {
        rune_count += 1;
        if (gostd.isSpace(item.value)) {
            in_field = false;
            continue;
        }
        if (!in_field) {
            in_field = true;
            count += 1;
        }
    }
    return .{ .rune_count = rune_count, .field_count = count };
}

/// Reports how similar query `a` is to candidate `b`. Both sides are already
/// known to be similarity candidates, rune counts are precomputed, and the word
/// overlap ratio was already derived from posting counts. The expensive
/// Levenshtein distance only runs when the cheap word-overlap and length-ratio
/// bounds show its threshold is still reachable: the edit similarity can never
/// exceed shorterLen/longerLen.
fn similarityDetails(
    allocator: std.mem.Allocator,
    transient: std.mem.Allocator,
    a: []const u8,
    a_runes: u32,
    b: []const u8,
    b_runes: u32,
    word_overlap: f64,
) !?Detail {
    var shorter = a;
    var longer = b;
    var shorter_len = a_runes;
    var longer_len = b_runes;
    var b_is_longer = true;
    if (a_runes > b_runes) {
        shorter = b;
        longer = a;
        shorter_len = b_runes;
        longer_len = a_runes;
        b_is_longer = false;
    }
    const length_ratio = @as(f64, @floatFromInt(shorter_len)) / @as(f64, @floatFromInt(longer_len));

    if (length_ratio >= 0.65 and std.mem.indexOf(u8, longer, shorter) != null) {
        const lead = if (b_is_longer)
            "source string is contained in the current translation value; "
        else
            "current translation value is contained in the source string; ";
        return Detail{
            .reason = "contained-substring",
            .score = @max(word_overlap, length_ratio),
            .why = try std.fmt.allocPrint(allocator, "{s}{d}% word overlap", .{ lead, percent(word_overlap) }),
        };
    }
    if (word_overlap >= 0.5 and length_ratio >= 0.78) {
        const edit_similarity = try levenshteinRatio(transient, a, b);
        if (edit_similarity >= 0.78) {
            return Detail{
                .reason = "edit-similarity",
                .score = edit_similarity,
                .why = try std.fmt.allocPrint(
                    allocator,
                    "{d}% edit similarity with {d}% word overlap",
                    .{ percent(edit_similarity), percent(word_overlap) },
                ),
            };
        }
    }
    if (word_overlap >= 0.7) {
        return Detail{
            .reason = "word-overlap",
            .score = word_overlap,
            .why = try std.fmt.allocPrint(allocator, "{d}% word overlap", .{percent(word_overlap)}),
        };
    }
    return null;
}

fn wordSet(allocator: std.mem.Allocator, value: []const u8, out: *std.StringHashMapUnmanaged(void)) !void {
    var start: ?usize = null;
    var it = gostd.runes(value);
    while (it.next()) |item| {
        if (gostd.isLetter(item.value) or gostd.isDigit(item.value)) {
            if (start == null) start = item.index;
            continue;
        }
        if (start) |s| {
            try out.put(allocator, value[s..item.index], {});
            start = null;
        }
    }
    if (start) |s| try out.put(allocator, value[s..], {});
}

fn levenshteinRatio(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !f64 {
    const a_runes = try toRunes(allocator, a);
    defer allocator.free(a_runes);
    const b_runes = try toRunes(allocator, b);
    defer allocator.free(b_runes);
    const max_len = @max(a_runes.len, b_runes.len);
    if (max_len == 0) return 1;
    const distance = try levenshteinDistance(allocator, a_runes, b_runes);
    return 1 - @as(f64, @floatFromInt(distance)) / @as(f64, @floatFromInt(max_len));
}

fn toRunes(allocator: std.mem.Allocator, s: []const u8) ![]u21 {
    var out: std.ArrayList(u21) = .empty;
    errdefer out.deinit(allocator);
    var it = gostd.runes(s);
    while (it.next()) |item| try out.append(allocator, item.value);
    return out.toOwnedSlice(allocator);
}

fn levenshteinDistance(allocator: std.mem.Allocator, a: []const u21, b: []const u21) !usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    var previous = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(previous);
    var current = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(current);
    for (previous, 0..) |*slot, j| slot.* = j;

    var i: usize = 1;
    while (i <= a.len) : (i += 1) {
        current[0] = i;
        var j: usize = 1;
        while (j <= b.len) : (j += 1) {
            const cost: usize = if (a[i - 1] != b[j - 1]) 1 else 0;
            current[j] = @min(@min(previous[j] + 1, current[j - 1] + 1), previous[j - 1] + cost);
        }
        std.mem.swap([]usize, &previous, &current);
    }
    return previous[b.len];
}

pub fn percent(score: f64) i64 {
    return @intFromFloat(score * 100 + 0.5);
}

// -- translation patterns ----------------------------------------------------

fn translationPatternTemplates(
    allocator: std.mem.Allocator,
    value: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    try icuPluralTemplates(allocator, value, out);
    if (out.items.len > 0) return;
    try out.append(allocator, value);
}

const Compiled = struct { elems: []const PatternElem, prefix: []const u8 };

/// Compiles a translation value into a matcher, also returning the pattern's
/// literal prefix (the normalized text before the first placeholder) which the
/// lookup uses to skip the matcher entirely.
///
/// A template only becomes a pattern when it has at least one placeholder and
/// at least three alphanumeric literal characters, which keeps bare
/// placeholders like "{count}" from matching everything.
fn compileTranslationPattern(allocator: std.mem.Allocator, template: []const u8) !?Compiled {
    const normalized = try normalize.normalize(allocator, template);

    var elems: std.ArrayList(PatternElem) = .empty;
    defer elems.deinit(allocator);
    var literal: std.ArrayList(u8) = .empty;
    defer literal.deinit(allocator);
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(allocator);

    var prefix_done = false;
    var placeholder_count: usize = 0;
    var literal_count: usize = 0;

    var i: usize = 0;
    while (i < normalized.len) : (i += 1) {
        switch (normalized[i]) {
            '{' => {
                const end = std.mem.indexOfScalar(u8, normalized[i + 1 ..], '}') orelse {
                    try literal.append(allocator, normalized[i]);
                    if (!prefix_done) try prefix.append(allocator, normalized[i]);
                    literal_count += 1;
                    continue;
                };
                const content = normalized[i + 1 .. i + 1 + end];
                if (content.len == 0 or
                    std.mem.indexOfScalar(u8, content, ',') != null or
                    std.mem.indexOfAny(u8, content, "{}") != null) return null;
                try flushLiteral(allocator, &elems, &literal);
                try elems.append(allocator, .any_plus);
                prefix_done = true;
                placeholder_count += 1;
                i += end + 1;
            },
            '#' => {
                try flushLiteral(allocator, &elems, &literal);
                try elems.append(allocator, .digits_plus);
                prefix_done = true;
                placeholder_count += 1;
            },
            else => {
                try literal.append(allocator, normalized[i]);
                if (!prefix_done) try prefix.append(allocator, normalized[i]);
                if (isPatternLiteral(normalized[i])) literal_count += 1;
            },
        }
    }
    try flushLiteral(allocator, &elems, &literal);
    if (placeholder_count == 0 or literal_count < 3) return null;
    return Compiled{
        .elems = try allocator.dupe(PatternElem, elems.items),
        .prefix = try allocator.dupe(u8, prefix.items),
    };
}

fn flushLiteral(
    allocator: std.mem.Allocator,
    elems: *std.ArrayList(PatternElem),
    literal: *std.ArrayList(u8),
) !void {
    if (literal.items.len == 0) return;
    try elems.append(allocator, .{ .literal = try allocator.dupe(u8, literal.items) });
    literal.clearRetainingCapacity();
}

fn isPatternLiteral(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= '0' and char <= '9');
}

/// Anchored full match with memoized backtracking. Patterns hold only a handful
/// of elements, but memoizing keeps a pathological translation value from
/// making the match exponential in the literal's length.
fn matchPattern(elems: []const PatternElem, s: []const u8, memo: []bool, width: usize) bool {
    if (elems.len == 0) return s.len == 0;
    const failed = memo[0 .. elems.len * width];
    @memset(failed, false);
    return matchFrom(elems, 0, s, 0, failed, width);
}

fn matchFrom(
    elems: []const PatternElem,
    ei: usize,
    s: []const u8,
    pos: usize,
    failed: []bool,
    width: usize,
) bool {
    if (ei == elems.len) return pos == s.len;
    const memo = ei * width + pos;
    if (failed[memo]) return false;

    const result = switch (elems[ei]) {
        .literal => |lit| blk: {
            if (!std.mem.startsWith(u8, s[pos..], lit)) break :blk false;
            break :blk matchFrom(elems, ei + 1, s, pos + lit.len, failed, width);
        },
        .any_plus => blk: {
            var p = pos;
            while (p < s.len) {
                const r = gostd.decodeRune(s[p..]);
                if (r.value == '\n') break;
                p += r.size;
                if (matchFrom(elems, ei + 1, s, p, failed, width)) break :blk true;
            }
            break :blk false;
        },
        .digits_plus => blk: {
            var p = pos;
            while (p < s.len and s[p] >= '0' and s[p] <= '9') {
                p += 1;
                if (matchFrom(elems, ei + 1, s, p, failed, width)) break :blk true;
            }
            break :blk false;
        },
    };
    if (!result) failed[memo] = true;
    return result;
}

/// Extracts the body of each plural category arm, so that "{count, plural, one
/// {# invite} other {# invites}}" yields "# invite" and "# invites".
fn icuPluralTemplates(
    allocator: std.mem.Allocator,
    value: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const normalized = try normalize.normalize(allocator, value);
    if (std.mem.indexOf(u8, normalized, "plural") == null) return;

    var i: usize = 0;
    while (i < normalized.len) {
        while (i < normalized.len and !isWordStart(normalized[i])) i += 1;
        const start = i;
        while (i < normalized.len and isWordPart(normalized[i])) i += 1;
        if (start == i) continue;
        if (!isPluralCategory(normalized[start..i])) continue;
        while (i < normalized.len and normalized[i] == ' ') i += 1;
        if (i >= normalized.len or normalized[i] != '{') continue;
        if (balancedBraces(normalized, i)) |body| {
            try out.append(allocator, body.text);
            i = body.next;
        }
    }
}

const Braces = struct { text: []const u8, next: usize };

fn balancedBraces(value: []const u8, start: usize) ?Braces {
    var depth: i32 = 0;
    var i = start;
    while (i < value.len) : (i += 1) {
        switch (value[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return .{ .text = value[start + 1 .. i], .next = i + 1 };
            },
            else => {},
        }
    }
    return null;
}

fn isPluralCategory(value: []const u8) bool {
    const categories = [_][]const u8{ "zero", "one", "two", "few", "many", "other" };
    for (categories) |category| {
        if (std.mem.eql(u8, value, category)) return true;
    }
    return false;
}

fn isWordStart(char: u8) bool {
    return char >= 'a' and char <= 'z';
}

fn isWordPart(char: u8) bool {
    return isWordStart(char) or char == '_';
}
