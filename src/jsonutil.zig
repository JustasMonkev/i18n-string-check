//! JSON parsing shared by the translation index, the config file and the
//! baseline.

const std = @import("std");

pub const Parsed = std.json.Parsed(std.json.Value);

/// Matches encoding/json's handling of a repeated key: the last one wins,
/// rather than being rejected.
pub const parse_options: std.json.ParseOptions = .{
    .duplicate_field_behavior = .use_last,
};

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Parsed {
    return std.json.parseFromSlice(std.json.Value, allocator, content, parse_options);
}

/// Describes where parsing failed, in the spirit of encoding/json's messages.
/// The wording is our own — Go's exact phrasing is not reproduced — but the
/// position makes the diagnostic at least as useful.
pub fn describeError(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var scanner = std.json.Scanner.initCompleteInput(allocator, content);
    defer scanner.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);

    while (true) {
        const token = scanner.next() catch |err| {
            const offset = diagnostics.getByteOffset();
            if (offset < content.len) {
                return std.fmt.allocPrint(allocator, "invalid character '{c}' at line {d} column {d}", .{
                    content[@intCast(offset)],
                    diagnostics.getLine(),
                    diagnostics.getColumn(),
                });
            }
            return std.fmt.allocPrint(allocator, "unexpected end of JSON input ({t})", .{err});
        };
        if (token == .end_of_document) break;
    }
    // The scanner accepted the input, so the failure came from the value tree
    // (for example a duplicate key under stricter options).
    return allocator.dupe(u8, "invalid JSON value");
}
