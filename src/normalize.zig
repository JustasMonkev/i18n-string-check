//! String preparation shared by the index and the extractor.

const std = @import("std");
const gostd = @import("gostd.zig");

/// Prepares English strings for matching.
// TODO: Replace with full Unicode case folding if/when supporting non-ASCII
// locale matching.
pub fn normalize(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const collapsed = try collapse(allocator, value);
    defer collapsed.deinit(allocator);
    return gostd.toLowerString(allocator, collapsed.bytes);
}

/// Trims the string and collapses every whitespace run into a single space.
/// Most inputs are already collapsed, so it first scans for a violation and
/// borrows the input when none is found.
pub fn collapse(allocator: std.mem.Allocator, value: []const u8) !gostd.Text {
    if (value.len == 0) return .borrow(value);

    var previous_space = true; // catches a leading space
    var clean = true;
    var it = gostd.runes(value);
    while (it.next()) |item| {
        if (item.value == ' ') {
            if (previous_space) {
                clean = false;
                break;
            }
            previous_space = true;
            continue;
        }
        if (gostd.isSpace(item.value)) {
            clean = false;
            break;
        }
        previous_space = false;
    }
    // previous_space still set after the loop means a trailing space.
    if (clean and !previous_space) return .borrow(value);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, value.len);
    var pending_space = false;
    var it2 = gostd.runes(value);
    while (it2.next()) |item| {
        if (gostd.isSpace(item.value)) {
            pending_space = out.items.len > 0;
            continue;
        }
        if (pending_space) {
            try out.append(allocator, ' ');
            pending_space = false;
        }
        var buf: [4]u8 = undefined;
        try out.appendSlice(allocator, gostd.encodeRune(&buf, item.value));
    }
    return .own(try out.toOwnedSlice(allocator));
}

/// collapse for callers that always want to own the result.
pub fn collapseWhitespace(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const text = try collapse(allocator, value);
    if (text.owned) return @constCast(text.bytes);
    return allocator.dupe(u8, text.bytes);
}

/// The length gate: collapsed byte length plus one extra per collapsed space,
/// which counts space-separated phrases conservatively.
pub fn trimmedLength(allocator: std.mem.Allocator, value: []const u8) !usize {
    const trimmed = try collapse(allocator, value);
    defer trimmed.deinit(allocator);
    return gateLength(trimmed.bytes);
}

/// gateLength of an already-collapsed string.
pub fn gateLength(collapsed: []const u8) usize {
    return collapsed.len + std.mem.count(u8, collapsed, " ");
}
