//! Go's `path/filepath` semantics.
//!
//! Exclude patterns, the walk's relative paths and the reported file paths all
//! depend on details that differ between filepath and Zig's std.fs.path: Clean
//! keeps a leading "..", Match refuses to let `*` cross a separator, and Rel is
//! purely lexical. Reimplementing them keeps discovery and reporting identical.
//!
//! Every routine is written against an explicit `Convention` rather than the
//! host's, so Windows volume handling — drive letters, UNC shares and local
//! device paths, which must survive cleaning intact — can be exercised from a
//! POSIX test run.

const std = @import("std");
const builtin = @import("builtin");
const gostd = @import("gostd.zig");

pub const Convention = enum {
    posix,
    windows,

    pub fn separator(comptime c: Convention) u8 {
        return switch (c) {
            .posix => '/',
            .windows => '\\',
        };
    }

    pub fn isSeparator(comptime c: Convention, b: u8) bool {
        return switch (c) {
            .posix => b == '/',
            .windows => b == '\\' or b == '/',
        };
    }

    /// filepath's `sameWord`, which ignores case on Windows.
    pub fn sameWord(comptime c: Convention, a: []const u8, b: []const u8) bool {
        return switch (c) {
            .posix => std.mem.eql(u8, a, b),
            .windows => std.ascii.eqlIgnoreCase(a, b),
        };
    }
};

pub const native: Convention = if (builtin.os.tag == .windows) .windows else .posix;

pub const separator: u8 = native.separator();

fn isSeparator(b: u8) bool {
    return native.isSeparator(b);
}

// -- volume names ------------------------------------------------------------

fn toUpper(b: u8) u8 {
    return if (b >= 'a' and b <= 'z') b - ('a' - 'A') else b;
}

fn pathHasPrefixFold(comptime c: Convention, s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (prefix, 0..) |p, i| {
        if (c.isSeparator(p)) {
            if (!c.isSeparator(s[i])) return false;
        } else if (toUpper(p) != toUpper(s[i])) return false;
    }
    if (s.len > prefix.len and !c.isSeparator(s[prefix.len])) return false;
    return true;
}

fn uncLen(comptime c: Convention, path: []const u8, prefix_len: usize) usize {
    var count: usize = 0;
    var i = prefix_len;
    while (i < path.len) : (i += 1) {
        if (c.isSeparator(path[i])) {
            count += 1;
            if (count == 2) return i;
        }
    }
    return path.len;
}

/// Length of the leading volume: a drive letter, a UNC `\\host\share`, or a
/// local-device prefix. Always zero on POSIX.
pub fn volumeNameLen(comptime c: Convention, path: []const u8) usize {
    if (c == .posix) return 0;

    if (path.len >= 2 and path[1] == ':') return 2;
    if (path.len == 0 or !c.isSeparator(path[0])) return 0;

    if (pathHasPrefixFold(c, path, "\\\\.\\UNC")) return uncLen(c, path, "\\\\.\\UNC\\".len);

    if (pathHasPrefixFold(c, path, "\\\\.") or
        pathHasPrefixFold(c, path, "\\\\?") or
        pathHasPrefixFold(c, path, "\\??"))
    {
        // The component after the prefix counts as part of the volume, so that
        // cleaning `\\?\c:\` keeps its trailing separator.
        if (path.len == 3) return 3;
        const rest = path[4..];
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (c.isSeparator(rest[i])) return path.len - (rest.len - i - 1) - 1;
        }
        return path.len;
    }

    if (path.len >= 2 and c.isSeparator(path[1])) return uncLen(c, path, 2);
    return 0;
}

pub fn volumeName(comptime c: Convention, path: []const u8) []const u8 {
    return path[0..volumeNameLen(c, path)];
}

// -- slash conversion --------------------------------------------------------

/// filepath.ToSlash.
pub fn toSlash(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    if (native == .posix) return out;
    for (out) |*b| {
        if (b.* == separator) b.* = '/';
    }
    return out;
}

fn fromSlashInPlace(comptime c: Convention, buf: []u8) void {
    if (c == .posix) return;
    for (buf) |*b| {
        if (b.* == '/') b.* = c.separator();
    }
}

// -- Ext / Base --------------------------------------------------------------

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

// -- Clean -------------------------------------------------------------------

/// filepath's `lazybuf`: it only starts a buffer once the output diverges from
/// the input, and Windows' post-cleaning step keys off whether that happened.
const LazyBuf = struct {
    allocator: std.mem.Allocator,
    /// The input with its volume removed.
    path: []const u8,
    buf: ?[]u8 = null,
    w: usize = 0,

    fn index(self: *const LazyBuf, i: usize) u8 {
        if (self.buf) |buf| return buf[i];
        return self.path[i];
    }

    fn append(self: *LazyBuf, ch: u8) !void {
        if (self.buf == null) {
            if (self.w < self.path.len and self.path[self.w] == ch) {
                self.w += 1;
                return;
            }
            const buf = try self.allocator.alloc(u8, self.path.len);
            @memcpy(buf[0..self.w], self.path[0..self.w]);
            self.buf = buf;
        }
        self.buf.?[self.w] = ch;
        self.w += 1;
    }

    fn prepend(self: *LazyBuf, prefix: []const u8) !void {
        const buf = self.buf orelse return;
        const grown = try self.allocator.alloc(u8, buf.len + prefix.len);
        @memcpy(grown[0..prefix.len], prefix);
        @memcpy(grown[prefix.len..][0..buf.len], buf);
        self.allocator.free(buf);
        self.buf = grown;
        self.w += prefix.len;
    }

    fn toOwned(self: *LazyBuf, volume: []const u8) ![]u8 {
        const tail = if (self.buf) |buf| buf[0..self.w] else self.path[0..self.w];
        const out = try self.allocator.alloc(u8, volume.len + tail.len);
        @memcpy(out[0..volume.len], volume);
        @memcpy(out[volume.len..], tail);
        if (self.buf) |buf| self.allocator.free(buf);
        self.buf = null;
        return out;
    }
};

/// Windows' `postClean`: keep a cleaned relative path from turning into a drive
/// or device path.
fn postClean(comptime c: Convention, out: *LazyBuf, vol_len: usize) !void {
    if (c == .posix) return;
    if (vol_len != 0 or out.buf == null) return;
    const buf = out.buf.?[0..out.w];

    // A ':' in the first element would otherwise make `a/../c:` read as a drive.
    for (buf) |ch| {
        if (c.isSeparator(ch)) break;
        if (ch == ':') {
            try out.prepend(&[_]u8{ '.', c.separator() });
            return;
        }
    }
    // A leading `\??\` would otherwise read as a root local device path.
    if (buf.len >= 3 and c.isSeparator(buf[0]) and buf[1] == '?' and buf[2] == '?') {
        try out.prepend(&[_]u8{ c.separator(), '.' });
    }
}

/// filepath.Clean.
pub fn clean(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return cleanIn(allocator, native, path);
}

pub fn cleanIn(allocator: std.mem.Allocator, comptime c: Convention, original: []const u8) ![]u8 {
    const vol_len = volumeNameLen(c, original);
    const path = original[vol_len..];
    if (path.len == 0) {
        if (vol_len > 1 and c.isSeparator(original[0]) and c.isSeparator(original[1])) {
            const out = try allocator.dupe(u8, original);
            fromSlashInPlace(c, out);
            return out;
        }
        return std.mem.concat(allocator, u8, &.{ original, "." });
    }

    const rooted = c.isSeparator(path[0]);
    // Invariants of the loop below:
    //   reading from path; r is the next byte to process.
    //   writing to out; out.w is the next byte to write.
    //   dotdot is the index in out where a ".." must stop backtracking.
    var out = LazyBuf{ .allocator = allocator, .path = path };
    errdefer if (out.buf) |buf| allocator.free(buf);

    var r: usize = 0;
    var dotdot: usize = 0;
    if (rooted) {
        try out.append(c.separator());
        r = 1;
        dotdot = 1;
    }

    while (r < path.len) {
        if (c.isSeparator(path[r])) {
            r += 1;
        } else if (path[r] == '.' and (r + 1 == path.len or c.isSeparator(path[r + 1]))) {
            r += 1;
        } else if (path[r] == '.' and r + 1 < path.len and path[r + 1] == '.' and
            (r + 2 == path.len or c.isSeparator(path[r + 2])))
        {
            r += 2;
            if (out.w > dotdot) {
                // Back up over the previous element.
                out.w -= 1;
                while (out.w > dotdot and !c.isSeparator(out.index(out.w))) out.w -= 1;
            } else if (!rooted) {
                // Cannot backtrack and not rooted, so keep the "..".
                if (out.w > 0) try out.append(c.separator());
                try out.append('.');
                try out.append('.');
                dotdot = out.w;
            }
        } else {
            if ((rooted and out.w != 1) or (!rooted and out.w != 0)) {
                try out.append(c.separator());
            }
            while (r < path.len and !c.isSeparator(path[r])) : (r += 1) {
                try out.append(path[r]);
            }
        }
    }

    if (out.w == 0) try out.append('.');
    try postClean(c, &out, vol_len);

    const result = try out.toOwned(original[0..vol_len]);
    fromSlashInPlace(c, result);
    return result;
}

// -- Join --------------------------------------------------------------------

/// filepath.Join.
pub fn join(allocator: std.mem.Allocator, elems: []const []const u8) ![]u8 {
    return joinIn(allocator, native, elems);
}

pub fn joinIn(allocator: std.mem.Allocator, comptime c: Convention, elems: []const []const u8) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);

    if (c == .posix) {
        for (elems, 0..) |elem, i| {
            if (elem.len == 0) continue;
            for (elems[i..], 0..) |rest, j| {
                if (j > 0) try joined.append(allocator, '/');
                try joined.appendSlice(allocator, rest);
            }
            break;
        }
    } else {
        var last: u8 = 0;
        for (elems) |elem_in| {
            var elem = elem_in;
            if (joined.items.len == 0) {
                // The first non-empty element is added unchanged.
            } else if (c.isSeparator(last)) {
                // Strip leading separators so joining cannot invent a UNC path.
                elem = std.mem.trimStart(u8, elem, "/\\");
                // Joining "??" onto a lone separator would spell a root local
                // device path, so an extra ".\" keeps it a plain path.
                if (joined.items.len == 1 and std.mem.startsWith(u8, elem, "??") and
                    (elem.len == 2 or c.isSeparator(elem[2])))
                {
                    try joined.appendSlice(allocator, ".\\");
                }
            } else if (last == ':') {
                // A trailing colon keeps the next element drive-relative.
            } else {
                try joined.append(allocator, '\\');
                last = '\\';
            }
            if (elem.len > 0) {
                try joined.appendSlice(allocator, elem);
                last = elem[elem.len - 1];
            }
        }
    }

    if (joined.items.len == 0) return allocator.alloc(u8, 0);
    return cleanIn(allocator, c, joined.items);
}

// -- Rel ---------------------------------------------------------------------

pub const RelError = error{CannotRelate} || std.mem.Allocator.Error;

/// filepath.Rel.
pub fn rel(allocator: std.mem.Allocator, basepath: []const u8, targpath: []const u8) RelError![]u8 {
    return relIn(allocator, native, basepath, targpath);
}

pub fn relIn(
    allocator: std.mem.Allocator,
    comptime c: Convention,
    basepath: []const u8,
    targpath: []const u8,
) RelError![]u8 {
    const base_vol = volumeName(c, basepath);
    const targ_vol = volumeName(c, targpath);
    const base_clean = try cleanIn(allocator, c, basepath);
    defer allocator.free(base_clean);
    const targ_clean = try cleanIn(allocator, c, targpath);
    defer allocator.free(targ_clean);

    if (c.sameWord(base_clean, targ_clean)) return allocator.dupe(u8, ".");

    const windows_root = [_]u8{c.separator()};
    var b: []const u8 = base_clean[base_vol.len..];
    const targ = targ_clean[targ_vol.len..];
    if (std.mem.eql(u8, b, ".")) {
        b = b[0..0];
    } else if (b.len == 0 and volumeNameLen(c, base_vol) > 2) {
        // A `\\host\share` base makes any target under it absolute.
        b = &windows_root;
    }

    // IsAbs is no help here: on Windows `\a` and `a` are both relative.
    const base_slashed = b.len > 0 and b[0] == c.separator();
    const targ_slashed = targ.len > 0 and targ[0] == c.separator();
    if (base_slashed != targ_slashed or !c.sameWord(base_vol, targ_vol)) return error.CannotRelate;

    // Advance past the shared leading path elements.
    const bl = b.len;
    const tl = targ.len;
    var b0: usize = 0;
    var bi: usize = 0;
    var t0: usize = 0;
    var ti: usize = 0;
    while (true) {
        while (bi < bl and b[bi] != c.separator()) bi += 1;
        while (ti < tl and targ[ti] != c.separator()) ti += 1;
        if (!c.sameWord(targ[t0..ti], b[b0..bi])) break;
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
            if (ch == c.separator()) seps += 1;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "..");
        var i: usize = 0;
        while (i < seps) : (i += 1) {
            try out.append(allocator, c.separator());
            try out.appendSlice(allocator, "..");
        }
        if (t0 != tl) {
            try out.append(allocator, c.separator());
            try out.appendSlice(allocator, targ[t0..]);
        }
        return out.toOwnedSlice(allocator);
    }
    return allocator.dupe(u8, targ[t0..]);
}

// -- Match -------------------------------------------------------------------

/// filepath.Match. Go reports a syntax error for malformed patterns and the
/// callers treat that as "no match", so a bad pattern simply returns false.
pub fn match(pattern: []const u8, name: []const u8) bool {
    return matchIn(native, pattern, name);
}

pub fn matchIn(comptime c: Convention, pattern: []const u8, name: []const u8) bool {
    return matchInner(c, pattern, name) catch false;
}

const MatchError = error{BadPattern};

fn matchInner(comptime c: Convention, pattern_in: []const u8, name_in: []const u8) MatchError!bool {
    var pattern = pattern_in;
    var name = name_in;
    while (pattern.len > 0) {
        const scanned = scanChunk(c, pattern);
        pattern = scanned.rest;
        if (scanned.star and scanned.chunk.len == 0) {
            // A trailing * matches the remainder unless it spans a separator.
            return std.mem.indexOfScalar(u8, name, c.separator()) == null;
        }
        if (try matchChunk(c, scanned.chunk, name)) |rest| {
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
            while (i < name.len and name[i] != c.separator()) : (i += 1) {
                if (try matchChunk(c, scanned.chunk, name[i + 1 ..])) |rest| {
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
            const tail = scanChunk(c, pattern);
            pattern = tail.rest;
            _ = try matchChunk(c, tail.chunk, "");
        }
        return false;
    }
    return name.len == 0;
}

const Chunk = struct { star: bool, chunk: []const u8, rest: []const u8 };

fn scanChunk(comptime c: Convention, pattern_in: []const u8) Chunk {
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
                if (c.separator() != '\\' and i + 1 < pattern.len) i += 1;
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
fn matchChunk(comptime c: Convention, chunk_in: []const u8, s_in: []const u8) MatchError!?[]const u8 {
    // Failing on an empty s early would skip the pattern's syntax check, so the
    // loop still runs and only the final result accounts for the empty input.
    var chunk = chunk_in;
    var s = s_in;
    var failed = false;
    while (chunk.len > 0) {
        if (!failed and s.len == 0) failed = true;
        switch (chunk[0]) {
            '[' => {
                // Zero, not undefined: when the name is already exhausted the
                // class is still parsed for syntax errors, and Go compares
                // against the zero rune rather than reading uninitialised memory.
                var r: u21 = 0;
                if (!failed) {
                    const decoded = gostd.decodeRune(s);
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
                    const first = try getEsc(c, chunk);
                    const lo: u21 = first.rune;
                    var hi: u21 = lo;
                    chunk = first.rest;
                    if (chunk.len > 0 and chunk[0] == '-') {
                        const second = try getEsc(c, chunk[1..]);
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
                    if (s[0] == c.separator()) failed = true else {
                        const decoded = gostd.decodeRune(s);
                        s = s[decoded.size..];
                    }
                }
                chunk = chunk[1..];
            },
            '\\' => {
                if (c.separator() != '\\') {
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

fn getEsc(comptime c: Convention, chunk_in: []const u8) MatchError!Esc {
    var chunk = chunk_in;
    if (chunk.len == 0 or chunk[0] == '-' or chunk[0] == ']') return error.BadPattern;
    if (chunk[0] == '\\' and c.separator() != '\\') {
        chunk = chunk[1..];
        if (chunk.len == 0) return error.BadPattern;
    }
    const decoded = gostd.decodeRune(chunk);
    if (decoded.value == gostd.rune_error and decoded.size == 1) return error.BadPattern;
    const rest = chunk[decoded.size..];
    if (rest.len == 0) return error.BadPattern;
    return .{ .rune = decoded.value, .rest = rest };
}
