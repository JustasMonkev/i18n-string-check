//! Minimal typed wrapper over the tree-sitter C API.
//!
//! Only the handful of calls the extractor needs are exposed. Nodes are plain
//! values in the C API, so they are copied freely; the owning `Tree` must
//! outlive any node taken from it.

const std = @import("std");

pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub extern fn tree_sitter_javascript() *const c.TSLanguage;
pub extern fn tree_sitter_typescript() *const c.TSLanguage;
pub extern fn tree_sitter_tsx() *const c.TSLanguage;

pub const Symbol = c.TSSymbol;

pub const Point = struct { row: u32, column: u32 };

pub const Node = struct {
    raw: c.TSNode,

    pub fn isNull(self: Node) bool {
        return c.ts_node_is_null(self.raw);
    }

    pub fn symbol(self: Node) Symbol {
        return c.ts_node_symbol(self.raw);
    }

    pub fn parent(self: Node) ?Node {
        const p = c.ts_node_parent(self.raw);
        if (c.ts_node_is_null(p)) return null;
        return .{ .raw = p };
    }

    pub fn childCount(self: Node) u32 {
        return c.ts_node_child_count(self.raw);
    }

    pub fn child(self: Node, i: u32) ?Node {
        const n = c.ts_node_child(self.raw, i);
        if (c.ts_node_is_null(n)) return null;
        return .{ .raw = n };
    }

    pub fn childByFieldName(self: Node, name: []const u8) ?Node {
        const n = c.ts_node_child_by_field_name(self.raw, name.ptr, @intCast(name.len));
        if (c.ts_node_is_null(n)) return null;
        return .{ .raw = n };
    }

    pub fn eql(self: Node, other: Node) bool {
        return c.ts_node_eq(self.raw, other.raw);
    }

    pub fn hasError(self: Node) bool {
        return c.ts_node_has_error(self.raw);
    }

    pub fn startPoint(self: Node) Point {
        const p = c.ts_node_start_point(self.raw);
        return .{ .row = p.row, .column = p.column };
    }

    /// The source text this node spans.
    pub fn content(self: Node, source: []const u8) []const u8 {
        const start = c.ts_node_start_byte(self.raw);
        const end = c.ts_node_end_byte(self.raw);
        if (start > end or end > source.len) return "";
        return source[start..end];
    }
};

pub const Tree = struct {
    raw: *c.TSTree,

    pub fn deinit(self: Tree) void {
        c.ts_tree_delete(self.raw);
    }

    pub fn rootNode(self: Tree) Node {
        return .{ .raw = c.ts_tree_root_node(self.raw) };
    }
};

pub const Parser = struct {
    raw: *c.TSParser,

    pub fn init() !Parser {
        return .{ .raw = c.ts_parser_new() orelse return error.OutOfMemory };
    }

    pub fn deinit(self: Parser) void {
        c.ts_parser_delete(self.raw);
    }

    pub fn setLanguage(self: Parser, language: *const c.TSLanguage) void {
        _ = c.ts_parser_set_language(self.raw, language);
    }

    pub fn parse(self: Parser, source: []const u8) !Tree {
        const tree = c.ts_parser_parse_string(
            self.raw,
            null,
            if (source.len == 0) "" else source.ptr,
            @intCast(source.len),
        );
        return .{ .raw = tree orelse return error.ParseFailed };
    }
};

pub const Query = struct {
    raw: *c.TSQuery,

    pub fn init(language: *const c.TSLanguage, source: []const u8) !Query {
        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = c.TSQueryErrorNone;
        const q = c.ts_query_new(language, source.ptr, @intCast(source.len), &error_offset, &error_type);
        return .{ .raw = q orelse return error.InvalidQuery };
    }

    pub fn deinit(self: Query) void {
        c.ts_query_delete(self.raw);
    }

    pub fn captureCount(self: Query) u32 {
        return c.ts_query_capture_count(self.raw);
    }

    pub fn captureNameForId(self: Query, id: u32) []const u8 {
        var length: u32 = 0;
        const name = c.ts_query_capture_name_for_id(self.raw, id, &length);
        return name[0..length];
    }
};

pub const Capture = struct { node: Node, index: u32 };

pub const QueryCursor = struct {
    raw: *c.TSQueryCursor,

    pub fn init() !QueryCursor {
        return .{ .raw = c.ts_query_cursor_new() orelse return error.OutOfMemory };
    }

    pub fn deinit(self: QueryCursor) void {
        c.ts_query_cursor_delete(self.raw);
    }

    pub fn exec(self: QueryCursor, query: Query, node: Node) void {
        c.ts_query_cursor_exec(self.raw, query.raw, node.raw);
    }

    /// Iterates matches; `captures` points into cursor-owned memory that the
    /// next call invalidates.
    pub fn nextMatch(self: QueryCursor, captures: *[]const Capture) bool {
        var match: c.TSQueryMatch = undefined;
        if (!c.ts_query_cursor_next_match(self.raw, &match)) return false;
        const raw: [*]const c.TSQueryCapture = @ptrCast(match.captures);
        capture_buffer_len = @min(match.capture_count, capture_buffer.len);
        for (0..capture_buffer_len) |i| {
            capture_buffer[i] = .{ .node = .{ .raw = raw[i].node }, .index = raw[i].index };
        }
        captures.* = capture_buffer[0..capture_buffer_len];
        return true;
    }
};

// A query match never carries many captures for the patterns used here; the
// buffer is thread-local because each worker drives its own cursor.
threadlocal var capture_buffer: [16]Capture = undefined;
threadlocal var capture_buffer_len: usize = 0;

pub fn languageSymbolCount(language: *const c.TSLanguage) u32 {
    return c.ts_language_symbol_count(language);
}

pub fn languageSymbolName(language: *const c.TSLanguage, symbol: Symbol) []const u8 {
    const name = c.ts_language_symbol_name(language, symbol) orelse return "";
    return std.mem.span(name);
}
