//! Go standard-library primitives that the checker's behaviour depends on.
//!
//! The matching rules were specified against Go's `unicode`, `strings` and
//! `strconv` packages, and its output formats against `fmt` verbs and
//! `encoding/json`. Reimplementing those semantics here — rather than reaching
//! for Zig's near-equivalents — is what keeps the port's results identical:
//! Go replaces malformed UTF-8 with U+FFFD instead of erroring, quotes strings
//! by Unicode printability, and escapes JSON for HTML safety by default.

const std = @import("std");
const tables = @import("unicode_tables.zig");

pub const rune_error: u21 = 0xFFFD;
pub const max_rune: u21 = 0x10FFFF;

pub const Rune = struct {
    value: u21,
    /// Bytes consumed. Always >= 1 for a non-empty input, so iteration
    /// terminates even on malformed UTF-8.
    size: usize,
};

/// utf8.DecodeRuneInString: malformed input yields (U+FFFD, 1) so that callers
/// advance one byte at a time, exactly as Go's `for range` over a string does.
pub fn decodeRune(s: []const u8) Rune {
    if (s.len == 0) return .{ .value = rune_error, .size = 0 };
    const b0 = s[0];
    if (b0 < 0x80) return .{ .value = b0, .size = 1 };

    // Accept ranges for the second byte, which is where overlong encodings,
    // surrogates and out-of-range code points are rejected.
    const Accept = struct { lo: u8, hi: u8, size: usize };
    const accept: Accept = switch (b0) {
        0xC2...0xDF => .{ .lo = 0x80, .hi = 0xBF, .size = 2 },
        0xE0 => .{ .lo = 0xA0, .hi = 0xBF, .size = 3 },
        0xE1...0xEC => .{ .lo = 0x80, .hi = 0xBF, .size = 3 },
        0xED => .{ .lo = 0x80, .hi = 0x9F, .size = 3 },
        0xEE...0xEF => .{ .lo = 0x80, .hi = 0xBF, .size = 3 },
        0xF0 => .{ .lo = 0x90, .hi = 0xBF, .size = 4 },
        0xF1...0xF3 => .{ .lo = 0x80, .hi = 0xBF, .size = 4 },
        0xF4 => .{ .lo = 0x80, .hi = 0x8F, .size = 4 },
        else => return .{ .value = rune_error, .size = 1 },
    };
    if (s.len < accept.size) return .{ .value = rune_error, .size = 1 };
    if (s[1] < accept.lo or s[1] > accept.hi) return .{ .value = rune_error, .size = 1 };

    var value: u21 = @as(u21, b0 & maskFor(accept.size));
    value = (value << 6) | @as(u21, s[1] & 0x3F);
    var i: usize = 2;
    while (i < accept.size) : (i += 1) {
        if (s[i] < 0x80 or s[i] > 0xBF) return .{ .value = rune_error, .size = 1 };
        value = (value << 6) | @as(u21, s[i] & 0x3F);
    }
    return .{ .value = value, .size = accept.size };
}

fn maskFor(size: usize) u8 {
    return switch (size) {
        2 => 0x1F,
        3 => 0x0F,
        else => 0x07,
    };
}

/// Iterates a string the way Go's `for i, r := range s` does.
pub const RuneIterator = struct {
    s: []const u8,
    index: usize = 0,

    pub const Item = struct { index: usize, value: u21, size: usize };

    pub fn next(self: *RuneIterator) ?Item {
        if (self.index >= self.s.len) return null;
        const start = self.index;
        const r = decodeRune(self.s[start..]);
        self.index = start + r.size;
        return .{ .index = start, .value = r.value, .size = r.size };
    }
};

pub fn runes(s: []const u8) RuneIterator {
    return .{ .s = s };
}

pub fn encodeRune(buf: *[4]u8, r: u21) []const u8 {
    // utf8.AppendRune maps surrogates and out-of-range values to U+FFFD.
    const value: u21 = if (r > max_rune or (r >= 0xD800 and r <= 0xDFFF)) rune_error else r;
    if (value < 0x80) {
        buf[0] = @intCast(value);
        return buf[0..1];
    }
    if (value < 0x800) {
        buf[0] = @intCast(0xC0 | (value >> 6));
        buf[1] = @intCast(0x80 | (value & 0x3F));
        return buf[0..2];
    }
    if (value < 0x10000) {
        buf[0] = @intCast(0xE0 | (value >> 12));
        buf[1] = @intCast(0x80 | ((value >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (value & 0x3F));
        return buf[0..3];
    }
    buf[0] = @intCast(0xF0 | (value >> 18));
    buf[1] = @intCast(0x80 | ((value >> 12) & 0x3F));
    buf[2] = @intCast(0x80 | ((value >> 6) & 0x3F));
    buf[3] = @intCast(0x80 | (value & 0x3F));
    return buf[0..4];
}

pub fn validRune(r: i32) bool {
    if (r < 0 or r > max_rune) return false;
    return !(r >= 0xD800 and r <= 0xDFFF);
}

// -- unicode predicates ------------------------------------------------------

pub fn isSpace(r: u21) bool {
    if (r < 0x80) return r == ' ' or (r >= '\t' and r <= '\r');
    return tables.isSpaceNonASCII(r);
}

pub fn isLetter(r: u21) bool {
    if (r < 0x80) return (r >= 'a' and r <= 'z') or (r >= 'A' and r <= 'Z');
    return tables.isLetterNonASCII(r);
}

pub fn isDigit(r: u21) bool {
    if (r < 0x80) return r >= '0' and r <= '9';
    return tables.isDigitNonASCII(r);
}

pub fn isPrint(r: u21) bool {
    if (r < 0x80) return r >= 0x20 and r <= 0x7E;
    return tables.isPrintNonASCII(r);
}

pub fn toLower(r: u21) u21 {
    if (r < 0x80) return if (r >= 'A' and r <= 'Z') r + ('a' - 'A') else r;
    return tables.toLowerNonASCII(r);
}

/// strings.ToLower. ASCII-only input takes the byte-wise path, and malformed
/// UTF-8 becomes U+FFFD, both matching Go.
pub fn toLowerString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var ascii = true;
    for (s) |b| {
        if (b >= 0x80) {
            ascii = false;
            break;
        }
    }
    if (ascii) {
        const out = try allocator.alloc(u8, s.len);
        for (s, 0..) |b, i| out[i] = if (b >= 'A' and b <= 'Z') b + ('a' - 'A') else b;
        return out;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, s.len);
    var it = runes(s);
    while (it.next()) |item| {
        var buf: [4]u8 = undefined;
        try out.appendSlice(allocator, encodeRune(&buf, toLower(item.value)));
    }
    return out.toOwnedSlice(allocator);
}

// -- strconv -----------------------------------------------------------------

const lowerhex = "0123456789abcdef";

/// strconv.Quote, which the text report uses through fmt's %q verb.
pub fn quote(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, s.len + 2);
    try out.append(allocator, '"');
    var i: usize = 0;
    while (i < s.len) {
        const r = decodeRune(s[i..]);
        if (r.size == 1 and r.value == rune_error and s[i] >= 0x80) {
            // Malformed byte: emit it as \xNN rather than U+FFFD.
            try out.appendSlice(allocator, "\\x");
            try out.append(allocator, lowerhex[s[i] >> 4]);
            try out.append(allocator, lowerhex[s[i] & 0xF]);
            i += 1;
            continue;
        }
        try appendEscapedRune(allocator, &out, r.value);
        i += r.size;
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn appendEscapedRune(allocator: std.mem.Allocator, out: *std.ArrayList(u8), r: u21) !void {
    if (r == '"' or r == '\\') {
        try out.append(allocator, '\\');
        try out.append(allocator, @intCast(r));
        return;
    }
    if (isPrint(r)) {
        var buf: [4]u8 = undefined;
        try out.appendSlice(allocator, encodeRune(&buf, r));
        return;
    }
    switch (r) {
        0x07 => try out.appendSlice(allocator, "\\a"),
        0x08 => try out.appendSlice(allocator, "\\b"),
        0x0C => try out.appendSlice(allocator, "\\f"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        0x0B => try out.appendSlice(allocator, "\\v"),
        else => {
            if (r < ' ' or r == 0x7F) {
                try out.appendSlice(allocator, "\\x");
                try out.append(allocator, lowerhex[(r >> 4) & 0xF]);
                try out.append(allocator, lowerhex[r & 0xF]);
            } else if (r < 0x10000) {
                try out.appendSlice(allocator, "\\u");
                var shift: i32 = 12;
                while (shift >= 0) : (shift -= 4) {
                    try out.append(allocator, lowerhex[(r >> @intCast(shift)) & 0xF]);
                }
            } else {
                try out.appendSlice(allocator, "\\U");
                var shift: i32 = 28;
                while (shift >= 0) : (shift -= 4) {
                    try out.append(allocator, lowerhex[(r >> @intCast(shift)) & 0xF]);
                }
            }
        },
    }
}

pub const UnquoteChar = struct {
    value: u21,
    tail: []const u8,
};

fn unhex(b: u8) ?u8 {
    return switch (b) {
        '0'...'9' => b - '0',
        'a'...'f' => b - 'a' + 10,
        'A'...'F' => b - 'A' + 10,
        else => null,
    };
}

/// strconv.UnquoteChar. `null` stands for Go's ErrSyntax; callers fall back to
/// the raw text, which is what the extractor does.
pub fn unquoteChar(s: []const u8, quote_char: u8) ?UnquoteChar {
    if (s.len == 0) return null;
    const c0 = s[0];
    if (c0 == quote_char and (quote_char == '\'' or quote_char == '"')) return null;
    if (c0 >= 0x80) {
        const r = decodeRune(s);
        return .{ .value = r.value, .tail = s[r.size..] };
    }
    if (c0 != '\\') return .{ .value = c0, .tail = s[1..] };

    if (s.len <= 1) return null;
    const c = s[1];
    var rest = s[2..];
    var value: u21 = undefined;
    switch (c) {
        'a' => value = 0x07,
        'b' => value = 0x08,
        'f' => value = 0x0C,
        'n' => value = '\n',
        'r' => value = '\r',
        't' => value = '\t',
        'v' => value = 0x0B,
        'x', 'u', 'U' => {
            const n: usize = switch (c) {
                'x' => 2,
                'u' => 4,
                else => 8,
            };
            if (rest.len < n) return null;
            var v: u32 = 0;
            var j: usize = 0;
            while (j < n) : (j += 1) {
                const x = unhex(rest[j]) orelse return null;
                v = (v << 4) | x;
            }
            rest = rest[n..];
            if (c == 'x') {
                value = @intCast(v);
            } else {
                if (v > max_rune or !validRune(@intCast(v))) return null;
                value = @intCast(v);
            }
        },
        '0'...'7' => {
            var v: u32 = c - '0';
            if (rest.len < 2) return null;
            var j: usize = 0;
            while (j < 2) : (j += 1) {
                if (rest[j] < '0' or rest[j] > '7') return null;
                v = (v << 3) | (rest[j] - '0');
            }
            rest = rest[2..];
            if (v > 255) return null;
            value = @intCast(v);
        },
        '\\' => value = '\\',
        '\'', '"' => {
            if (c != quote_char) return null;
            value = c;
        },
        else => return null,
    }
    return .{ .value = value, .tail = rest };
}

// -- encoding/json -----------------------------------------------------------

/// encoding/json's string encoder with the default HTML escaping enabled, so
/// `<`, `>` and `&` come out as <, > and & like Go's.
pub fn appendJSONString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            if (b >= 0x20 and b != '"' and b != '\\' and b != '<' and b != '>' and b != '&') {
                try out.append(allocator, b);
                i += 1;
                continue;
            }
            switch (b) {
                '\\', '"' => {
                    try out.append(allocator, '\\');
                    try out.append(allocator, b);
                },
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => {
                    try out.appendSlice(allocator, "\\u00");
                    try out.append(allocator, lowerhex[b >> 4]);
                    try out.append(allocator, lowerhex[b & 0xF]);
                },
            }
            i += 1;
            continue;
        }
        const r = decodeRune(s[i..]);
        if (r.value == rune_error and r.size == 1) {
            try out.appendSlice(allocator, "\\ufffd");
            i += 1;
            continue;
        }
        if (r.value == 0x2028 or r.value == 0x2029) {
            try out.appendSlice(allocator, "\\u202");
            try out.append(allocator, lowerhex[r.value & 0xF]);
            i += r.size;
            continue;
        }
        try out.appendSlice(allocator, s[i .. i + r.size]);
        i += r.size;
    }
    try out.append(allocator, '"');
}

/// encoding/json's float encoder: fixed notation with the shortest
/// round-tripping decimal, switching to exponent form only outside
/// [1e-6, 1e21). Scores stay well inside that window, so the exponent branch
/// exists for completeness rather than for the checker's own output.
pub fn appendJSONFloat(allocator: std.mem.Allocator, out: *std.ArrayList(u8), f: f64) !void {
    var buf: [512]u8 = undefined;
    const abs = @abs(f);
    const scientific = abs != 0 and (abs < 1e-6 or abs >= 1e21);
    const rendered = std.fmt.float.render(&buf, f, .{
        .mode = if (scientific) .scientific else .decimal,
    }) catch unreachable;
    if (!scientific) {
        try out.appendSlice(allocator, rendered);
        return;
    }
    // Go writes a sign on positive exponents ("1e+21"); Zig omits it.
    const e = std.mem.indexOfScalar(u8, rendered, 'e') orelse {
        try out.appendSlice(allocator, rendered);
        return;
    };
    try out.appendSlice(allocator, rendered[0 .. e + 1]);
    if (e + 1 < rendered.len and rendered[e + 1] != '-' and rendered[e + 1] != '+') {
        try out.append(allocator, '+');
    }
    try out.appendSlice(allocator, rendered[e + 1 ..]);
}

/// utf8.DecodeLastRuneInString, including its guard against quadratic scanning
/// of malformed input.
pub fn decodeLastRune(s: []const u8) Rune {
    if (s.len == 0) return .{ .value = rune_error, .size = 0 };
    var start = s.len - 1;
    if (s[start] < 0x80) return .{ .value = s[start], .size = 1 };

    const lim = if (s.len < 4) 0 else s.len - 4;
    while (start > lim) {
        start -= 1;
        if (isRuneStart(s[start])) break;
    }
    const r = decodeRune(s[start..]);
    if (start + r.size != s.len) return .{ .value = rune_error, .size = 1 };
    return r;
}

fn isRuneStart(b: u8) bool {
    return (b & 0xC0) != 0x80;
}
