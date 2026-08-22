//! Finding output, in both the human-readable and the machine-readable form.

const std = @import("std");
const gostd = @import("gostd.zig");
const index = @import("index.zig");

pub const Finding = struct {
    file: []const u8,
    line: usize,
    column: usize,
    type: []const u8,
    literal: []const u8,
    normalized_literal: []const u8,
    matches: []const index.Match,
};

pub const Summary = struct {
    found: bool,
    count: usize,
    files: usize,
    /// Null reproduces Go's nil slice, which serializes as JSON `null` rather
    /// than `[]`. A baseline that filters every finding leaves an empty — but
    /// not nil — slice, and the two are distinguishable in the output.
    findings: ?[]Finding,
};

pub fn newSummary(allocator: std.mem.Allocator, findings: ?[]Finding) !Summary {
    const items: []Finding = findings orelse &[_]Finding{};
    sortFindings(items);
    var files: std.StringHashMapUnmanaged(void) = .empty;
    defer files.deinit(allocator);
    for (items) |finding| try files.put(allocator, finding.file, {});
    return .{
        .found = items.len > 0,
        .count = items.len,
        .files = files.count(),
        .findings = findings,
    };
}

pub fn sortFindings(findings: []Finding) void {
    std.mem.sort(Finding, findings, {}, lessThan);
}

fn lessThan(_: void, a: Finding, b: Finding) bool {
    switch (std.mem.order(u8, a.file, b.file)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.line != b.line) return a.line < b.line;
    return a.column < b.column;
}

const changed_translation_value = "changed-translation-value";
const test_value_mismatch = "test-value-mismatch";

pub fn writeText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), summary: Summary) !void {
    for (summary.findings orelse &[_]Finding{}) |finding| {
        if (std.mem.eql(u8, finding.type, changed_translation_value)) {
            try writeLikelyStaleText(allocator, out, finding);
            continue;
        }
        try print(allocator, out, "{s}: {s}:{d}\n", .{ findingTitle(finding), finding.file, finding.line });
        try printQuoted(allocator, out, "  literal: ", finding.literal, "\n");
        if (finding.matches.len == 1) {
            const match = finding.matches[0];
            const key = try gostd.quote(allocator, match.key);
            defer allocator.free(key);
            const value = try gostd.quote(allocator, match.value);
            defer allocator.free(value);
            try print(allocator, out, "  matches en.json key: {s} value: {s}\n", .{ key, value });
            try writeFix(allocator, out, finding, match.key);
        } else {
            try print(allocator, out, "  matches multiple en.json keys:\n", .{});
            for (finding.matches) |match| {
                const key = try gostd.quote(allocator, match.key);
                defer allocator.free(key);
                const value = try gostd.quote(allocator, match.value);
                defer allocator.free(value);
                try print(allocator, out, "    - {s} value: {s}\n", .{ key, value });
            }
            try print(allocator, out, "  fix: {s}\n", .{multiFixText(finding)});
        }
        try print(allocator, out, "\n", .{});
    }
    if (summary.count > 0) {
        try print(allocator, out, "→ {d} i18n issues found in {d} files.\n", .{ summary.count, summary.files });
        return;
    }
    try print(allocator, out, "no i18n issues found.\n", .{});
}

fn writeLikelyStaleText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), finding: Finding) !void {
    try print(allocator, out, "{s}: {s}:{d}\n", .{ findingTitle(finding), finding.file, finding.line });
    try print(allocator, out, "  current code string:\n", .{});
    try printQuoted(allocator, out, "    ", finding.literal, "\n\n");

    if (finding.matches.len == 1) {
        const match = finding.matches[0];
        try print(allocator, out, "  similar en.json value:\n", .{});
        try printQuoted(allocator, out, "    key: ", match.key, "\n");
        try printQuoted(allocator, out, "    value: ", match.value, "\n\n");
        try print(allocator, out, "  similarity: {d}%\n", .{index.percent(match.detail.score)});
        try print(allocator, out, "  why: {s}\n", .{
            fallback(match.detail.why, "similar to the current en.json value"),
        });
        try writeFix(allocator, out, finding, match.key);
        try print(allocator, out, "\n", .{});
        return;
    }

    try print(allocator, out, "  similar en.json values:\n", .{});
    for (finding.matches, 0..) |match, i| {
        const key = try gostd.quote(allocator, match.key);
        defer allocator.free(key);
        const value = try gostd.quote(allocator, match.value);
        defer allocator.free(value);
        try print(allocator, out, "    {d}. key: {s} value: {s} similarity: {d}%\n", .{
            i + 1, key, value, index.percent(match.detail.score),
        });
        if (match.detail.why.len > 0) {
            try print(allocator, out, "       why: {s}\n", .{match.detail.why});
        }
    }
    try print(allocator, out, "  fix: {s}\n", .{multiFixText(finding)});
    try print(allocator, out, "\n", .{});
}

fn writeFix(allocator: std.mem.Allocator, out: *std.ArrayList(u8), finding: Finding, key: []const u8) !void {
    if (std.mem.eql(u8, finding.type, changed_translation_value)) {
        try print(allocator, out, "  fix: replace with t(\"{s}\"), or mark this literal intentional\n", .{key});
        return;
    }
    if (std.mem.eql(u8, finding.type, test_value_mismatch)) {
        const quoted = try gostd.quote(allocator, key);
        defer allocator.free(quoted);
        try print(allocator, out, "  fix: update the test literal to the current en.json value for {s}\n", .{quoted});
        return;
    }
    try print(allocator, out, "  fix: replace with t(\"{s}\") or your project's i18n helper\n", .{key});
}

fn findingTitle(finding: Finding) []const u8 {
    if (std.mem.eql(u8, finding.type, changed_translation_value)) return "likely stale hardcoded translation";
    if (std.mem.eql(u8, finding.type, test_value_mismatch)) return "translation value mismatch";
    return "hardcoded translation";
}

fn multiFixText(finding: Finding) []const u8 {
    if (std.mem.eql(u8, finding.type, changed_translation_value)) {
        return "choose the correct t(\"...\") key, or mark this literal intentional";
    }
    if (std.mem.eql(u8, finding.type, test_value_mismatch)) {
        return "update the test literal to the correct current en.json value for this context";
    }
    return "replace with the correct t(\"...\") key for this context";
}

fn fallback(value: []const u8, replacement: []const u8) []const u8 {
    return if (value.len == 0) replacement else value;
}

fn print(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    comptime format: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn printQuoted(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    prefix: []const u8,
    value: []const u8,
    suffix: []const u8,
) !void {
    const quoted = try gostd.quote(allocator, value);
    defer allocator.free(quoted);
    try out.appendSlice(allocator, prefix);
    try out.appendSlice(allocator, quoted);
    try out.appendSlice(allocator, suffix);
}

// -- JSON --------------------------------------------------------------------

/// Mirrors encoding/json with `SetIndent("", "  ")`: two-space indentation,
/// struct field order, `omitempty` on the match detail, and a trailing newline.
pub fn writeJSON(allocator: std.mem.Allocator, out: *std.ArrayList(u8), summary: Summary) !void {
    try out.appendSlice(allocator, "{\n");
    try print(allocator, out, "  \"found\": {s},\n", .{if (summary.found) "true" else "false"});
    try print(allocator, out, "  \"count\": {d},\n", .{summary.count});
    try print(allocator, out, "  \"files\": {d},\n", .{summary.files});
    try out.appendSlice(allocator, "  \"findings\": ");
    if (summary.findings) |findings| {
        if (findings.len == 0) {
            try out.appendSlice(allocator, "[]");
        } else {
            try out.appendSlice(allocator, "[\n");
            for (findings, 0..) |finding, i| {
                try writeFindingJSON(allocator, out, finding);
                try out.appendSlice(allocator, if (i + 1 == findings.len) "\n" else ",\n");
            }
            try out.appendSlice(allocator, "  ]");
        }
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.appendSlice(allocator, "\n}\n");
}

fn writeFindingJSON(allocator: std.mem.Allocator, out: *std.ArrayList(u8), finding: Finding) !void {
    try out.appendSlice(allocator, "    {\n");
    try writeJSONField(allocator, out, "      ", "file", finding.file, ",\n");
    try print(allocator, out, "      \"line\": {d},\n", .{finding.line});
    try print(allocator, out, "      \"column\": {d},\n", .{finding.column});
    try writeJSONField(allocator, out, "      ", "type", finding.type, ",\n");
    try writeJSONField(allocator, out, "      ", "literal", finding.literal, ",\n");
    try writeJSONField(allocator, out, "      ", "normalizedLiteral", finding.normalized_literal, ",\n");
    try out.appendSlice(allocator, "      \"matches\": ");
    if (finding.matches.len == 0) {
        // Go's nil slice; an allocated-but-empty one cannot occur here.
        try out.appendSlice(allocator, "null");
    } else {
        try out.appendSlice(allocator, "[\n");
        for (finding.matches, 0..) |match, i| {
            try writeMatchJSON(allocator, out, match);
            try out.appendSlice(allocator, if (i + 1 == finding.matches.len) "\n" else ",\n");
        }
        try out.appendSlice(allocator, "      ]");
    }
    try out.appendSlice(allocator, "\n    }");
}

fn writeMatchJSON(allocator: std.mem.Allocator, out: *std.ArrayList(u8), match: index.Match) !void {
    try out.appendSlice(allocator, "        {\n");
    try writeJSONField(allocator, out, "          ", "key", match.key, ",\n");
    // The trailing comma depends on which omitempty fields follow.
    const has_reason = match.detail.reason.len > 0;
    const has_score = match.detail.score != 0;
    const has_why = match.detail.why.len > 0;
    try writeJSONField(
        allocator,
        out,
        "          ",
        "value",
        match.value,
        if (has_reason or has_score or has_why) ",\n" else "\n",
    );
    if (has_reason) {
        try writeJSONField(
            allocator,
            out,
            "          ",
            "reason",
            match.detail.reason,
            if (has_score or has_why) ",\n" else "\n",
        );
    }
    if (has_score) {
        try out.appendSlice(allocator, "          \"score\": ");
        try gostd.appendJSONFloat(allocator, out, match.detail.score);
        try out.appendSlice(allocator, if (has_why) ",\n" else "\n");
    }
    if (has_why) {
        try writeJSONField(allocator, out, "          ", "why", match.detail.why, "\n");
    }
    try out.appendSlice(allocator, "        }");
}

fn writeJSONField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    name: []const u8,
    value: []const u8,
    suffix: []const u8,
) !void {
    try out.appendSlice(allocator, indent);
    try gostd.appendJSONString(allocator, out, name);
    try out.appendSlice(allocator, ": ");
    try gostd.appendJSONString(allocator, out, value);
    try out.appendSlice(allocator, suffix);
}
