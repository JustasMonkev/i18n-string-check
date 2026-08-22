//! Go's `path/filepath` semantics.
//!
//! Exclude patterns, the walk's relative paths and the reported file paths all
//! depend on details that differ between filepath and Zig's std.fs.path: Clean
//! keeps a leading "..", Match refuses to let `*` cross a separator, and Rel is
//! purely lexical. Reimplementing them keeps discovery and reporting identical.

const std = @import("std");
const builtin = @import("builtin");

pub const separator: u8 = if (builtin.os.tag == .windows) '\\' else '/';

fn isSeparator(b: u8) bool {
    if (builtin.os.tag == .windows) return b == '\\' or b == '/';
    return b == '/';
}

/// filepath.ToSlash.
pub fn toSlash(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    if (separator == '/') return out;
    for (out) |*b| {
        if (b.* == separator) b.* = '/';
    }
    return out;
}

/// filepath.Ext: the suffix from the final dot in the last element, or "".
pub fn ext(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (isSeparator(path[i])) break;
        if (path[i] == '.') return path[i..];
    }
    return path[path.len..];
}

/// filepath.Base.
pub fn base(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    var p = path;
    while (p.len > 0 and isSeparator(p[p.len - 1])) p = p[0 .. p.len - 1];
    if (p.len == 0) return &[_]u8{separator};
    var i: usize = p.len;
    while (i > 0) {
        if (isSeparator(p[i - 1])) return p[i..];
        i -= 1;
    }
    return p;
}

/// filepath.Clean.
pub fn clean(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8, ".");

    const rooted = isSeparator(path[0]);
    // Invariants of the loop below:
    //   reading from path; r is the next byte to process.
    //   writing to out; w is the next byte to write.
    //   dotdot is the index in out where a ".." must stop backtracking.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, path.len + 1);

    var r: usize = 0;
    var dotdot: usize = 0;
    if (rooted) {
        try out.append(allocator, separator);
        r = 1;
        dotdot = 1;
    }

    while (r < path.len) {
        if (isSeparator(path[r])) {
            r += 1;
        } else if (path[r] == '.' and (r + 1 == path.len or isSeparator(path[r + 1]))) {
            r += 1;
        } else if (path[r] == '.' and path[r + 1] == '.' and (r + 2 == path.len or isSeparator(path[r + 2]))) {
            r += 2;
            if (out.items.len > dotdot) {
                // Back up over the previous element.
                var w = out.items.len - 1;
                while (w > dotdot and !isSeparator(out.items[w])) w -= 1;
                out.shrinkRetainingCapacity(w);
            } else if (!rooted) {
                if (out.items.len > 0) try out.append(allocator, separator);
                try out.appendSlice(allocator, "..");
                dotdot = out.items.len;
            }
        } else {
            if ((rooted and out.items.len != 1) or (!rooted and out.items.len != 0)) {
                try out.append(allocator, separator);
            }
            while (r < path.len and !isSeparator(path[r])) : (r += 1) {
                try out.append(allocator, path[r]);
            }
        }
    }

    if (out.items.len == 0) try out.append(allocator, '.');
    return out.toOwnedSlice(allocator);
}

/// filepath.Join: joins the non-empty elements with a separator and cleans the
/// result, so joining onto "." does not leave a "./" prefix.
pub fn join(allocator: std.mem.Allocator, elems: []const []const u8) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    for (elems) |elem| {
        if (elem.len == 0) continue;
        if (joined.items.len > 0) try joined.append(allocator, separator);
        try joined.appendSlice(allocator, elem);
    }
    if (joined.items.len == 0) return allocator.alloc(u8, 0);
    return clean(allocator, joined.items);
}

pub const RelError = error{CannotRelate} || std.mem.Allocator.Error;

/// filepath.Rel, restricted to the volume-free paths this tool sees.
pub fn rel(allocator: std.mem.Allocator, basepath: []const u8, targpath: []const u8) RelError![]u8 {
    const base_clean = try clean(allocator, basepath);
    defer allocator.free(base_clean);
    const targ_clean = try clean(allocator, targpath);
    defer allocator.free(targ_clean);

    if (std.mem.eql(u8, base_clean, targ_clean)) return allocator.dupe(u8, ".");

    var b = base_clean;
    if (std.mem.eql(u8, b, ".")) b = b[0..0];

    const base_slashed = b.len > 0 and isSeparator(b[0]);
    const targ_slashed = targ_clean.len > 0 and isSeparator(targ_clean[0]);
    if (base_slashed != targ_slashed) return error.CannotRelate;

    // Advance past the shared leading path elements.
    const bl = b.len;
    const tl = targ_clean.len;
    var b0: usize = 0;
    var bi: usize = 0;
    var t0: usize = 0;
    var ti: usize = 0;
    while (true) {
        while (bi < bl and !isSeparator(b[bi])) bi += 1;
        while (ti < tl and !isSeparator(targ_clean[ti])) ti += 1;
        if (!std.mem.eql(u8, targ_clean[t0..ti], b[b0..bi])) break;
        if (bi < bl) bi += 1;
        if (ti < tl) ti += 1;
        b0 = bi;
        t0 = ti;
    }
    if (std.mem.eql(u8, b[b0..bi], "..")) return error.CannotRelate;

    if (b0 != bl) {
        // Elements remain in base, so climb out of them before descending.
        var seps: usize = 0;
        for (b[b0..bl]) |ch| {
            if (isSeparator(ch)) seps += 1;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "..");
        var i: usize = 0;
        while (i < seps) : (i += 1) {
            try out.append(allocator, separator);
            try out.appendSlice(allocator, "..");
        }
        if (t0 != tl) {
            try out.append(allocator, separator);
            try out.appendSlice(allocator, targ_clean[t0..]);
        }
        return out.toOwnedSlice(allocator);
    }
    return allocator.dupe(u8, targ_clean[t0..]);
}

/// filepath.Match. Go reports a syntax error for malformed patterns and the
/// callers treat that as "no match", so a bad pattern simply returns false.
pub fn match(pattern: []const u8, name: []const u8) bool {
    return matchInner(pattern, name) catch false;
}

const MatchError = error{BadPattern};

fn matchInner(pattern_in: []const u8, name_in: []const u8) MatchError!bool {
    var pattern = pattern_in;
    var name = name_in;
    while (pattern.len > 0) {
        const scanned = scanChunk(pattern);
        pattern = scanned.rest;
        if (scanned.star and scanned.chunk.len == 0) {
            // A trailing * matches the remainder unless it spans a separator.
            return std.mem.indexOfScalar(u8, name, separator) == null;
        }
        if (try matchChunk(scanned.chunk, name)) |rest| {
            // Only accept here if this was not the last chunk, or the name is
            // fully consumed; otherwise the star still has work to do.
            if (rest.len == 0 or pattern.len > 0) {
                name = rest;
                continue;
            }
        }
        if (scanned.star) {
            // Retry after skipping one more byte of name, never past a separator.
            var i: usize = 0;
            var matched = false;
            while (i < name.len and name[i] != separator) : (i += 1) {
                if (try matchChunk(scanned.chunk, name[i + 1 ..])) |rest| {
                    if (pattern.len == 0 and rest.len > 0) continue;
                    name = rest;
                    matched = true;
                    break;
                }
            }
            if (matched) continue;
        }
        // Validate the rest of the pattern before reporting no match, so that a
        // malformed pattern is still reported as malformed.
        while (pattern.len > 0) {
            const tail = scanChunk(pattern);
            pattern = tail.rest;
            _ = try matchChunk(tail.chunk, "");
        }
        return false;
    }
    return name.len == 0;
}

const Chunk = struct { star: bool, chunk: []const u8, rest: []const u8 };

fn scanChunk(pattern_in: []const u8) Chunk {
    var pattern = pattern_in;
    var star = false;
    while (pattern.len > 0 and pattern[0] == '*') {
        pattern = pattern[1..];
        star = true;
    }
    var in_range = false;
    var i: usize = 0;
    scan: while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => {
                if (separator != '\\' and i + 1 < pattern.len) i += 1;
            },
            '[' => in_range = true,
            ']' => in_range = false,
            '*' => if (!in_range) break :scan,
            else => {},
        }
    }
    return .{ .star = star, .chunk = pattern[0..i], .rest = pattern[i..] };
}

/// Returns the unmatched remainder of `s`, or null when the chunk does not
/// match its prefix.
fn matchChunk(chunk_in: []const u8, s_in: []const u8) MatchError!?[]const u8 {
    // Failing on an empty s early would skip the pattern's syntax check, so the
    // loop still runs and only the final result accounts for the empty input.
    var chunk = chunk_in;
    var s = s_in;
    var failed = false;
    while (chunk.len > 0) {
        if (!failed and s.len == 0) failed = true;
        switch (chunk[0]) {
            '[' => {
                var r: u21 = undefined;
                if (!failed) {
                    const decoded = @import("gostd.zig").decodeRune(s);
                    r = decoded.value;
                    s = s[decoded.size..];
                }
                chunk = chunk[1..];
                // A leading '^' negates the class.
                var negated = false;
                if (chunk.len > 0 and chunk[0] == '^') {
                    negated = true;
                    chunk = chunk[1..];
                }
                var mtch = false;
                var range_count: usize = 0;
                while (true) {
                    if (chunk.len > 0 and chunk[0] == ']' and range_count > 0) {
                        chunk = chunk[1..];
                        break;
                    }
                    if (chunk.len == 0) return error.BadPattern;
                    var lo: u21 = undefined;
                    var hi: u21 = undefined;
                    const first = try getEsc(chunk);
                    lo = first.rune;
                    hi = lo;
                    chunk = first.rest;
                    if (chunk.len > 0 and chunk[0] == '-') {
                        const second = try getEsc(chunk[1..]);
                        hi = second.rune;
                        chunk = second.rest;
                    }
                    if (lo <= r and r <= hi) mtch = true;
                    range_count += 1;
                }
                if (mtch == negated) failed = true;
            },
            '?' => {
                if (!failed) {
                    if (s[0] == separator) failed = true else {
                        const decoded = @import("gostd.zig").decodeRune(s);
                        s = s[decoded.size..];
                    }
                }
                chunk = chunk[1..];
            },
            '\\' => {
                if (separator != '\\') {
                    chunk = chunk[1..];
                    if (chunk.len == 0) return error.BadPattern;
                }
                if (!failed) {
                    if (chunk[0] != s[0]) failed = true else s = s[1..];
                }
                chunk = chunk[1..];
            },
            else => {
                if (!failed) {
                    if (chunk[0] != s[0]) failed = true else s = s[1..];
                }
                chunk = chunk[1..];
            },
        }
    }
    if (failed) return null;
    return s;
}

const Esc = struct { rune: u21, rest: []const u8 };

fn getEsc(chunk_in: []const u8) MatchError!Esc {
    var chunk = chunk_in;
    if (chunk.len == 0 or chunk[0] == '-' or chunk[0] == ']') return error.BadPattern;
    if (chunk[0] == '\\' and separator != '\\') {
        chunk = chunk[1..];
        if (chunk.len == 0) return error.BadPattern;
    }
    const decoded = @import("gostd.zig").decodeRune(chunk);
    if (decoded.value == @import("gostd.zig").rune_error and decoded.size == 1) return error.BadPattern;
    const rest = chunk[decoded.size..];
    if (rest.len == 0) return error.BadPattern;
    return .{ .rune = decoded.value, .rest = rest };
}
