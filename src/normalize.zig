//! String preparation shared by the index and the extractor.

const std = @import("std");
const gostd = @import("gostd.zig");

/// Prepares English strings for matching.
// TODO: Replace with full Unicode case folding if/when supporting non-ASCII
// locale matching.
pub fn normalize(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const collapsed = try collapseWhitespace(allocator, value);
    defer allocator.free(collapsed);
    return gostd.toLowerString(allocator, collapsed);
}

/// Trims the string and collapses every whitespace run into a single space.
/// Most inputs are already collapsed, so it first scans for a violation and
/// returns a copy of the input when none is found.
pub fn collapseWhitespace(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return allocator.alloc(u8, 0);

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
    if (clean and !previous_space) return allocator.dupe(u8, value);

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
    return out.toOwnedSlice(allocator);
}

/// The length gate: collapsed byte length plus one extra per collapsed space,
/// which counts space-separated phrases conservatively.
pub fn trimmedLength(allocator: std.mem.Allocator, value: []const u8) !usize {
    const trimmed = try collapseWhitespace(allocator, value);
    defer allocator.free(trimmed);
    return gateLength(trimmed);
}

/// gateLength of an already-collapsed string.
pub fn gateLength(collapsed: []const u8) usize {
    return collapsed.len + std.mem.count(u8, collapsed, " ");
}
