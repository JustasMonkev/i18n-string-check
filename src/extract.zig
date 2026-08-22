//! Pulls user-visible string literals out of TypeScript and JavaScript sources.
//!
//! Candidates come from a tree-sitter query rather than a full AST walk, and
//! the context filters that reject object keys, type-literal keys, import and
//! require paths and non-visible JSX attributes share a single walk up the
//! ancestor chain.

const std = @import("std");
const gostd = @import("gostd.zig");
const gopath = @import("gopath.zig");
const normalize = @import("normalize.zig");
const ts = @import("treesitter.zig");

pub const Literal = struct {
    file: []const u8,
    line: usize,
    column: usize,
    literal: []const u8,
    normalized_literal: []const u8,
};

/// Reports whether a normalized literal is worth keeping. It lets callers that
/// only care about literals matching an index skip the per-literal context
/// filters for everything else.
pub const MatchFunc = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, normalized: []const u8) anyerror!bool,

    pub fn worth(self: MatchFunc, normalized: []const u8) !bool {
        return self.call(self.ctx, normalized);
    }
};

pub const ignore_marker = "i18n-string-check-ignore";

const LiteralKind = enum { string, template, jsx_text };

/// Groups the node types the context filters care about. Classifying by
/// numeric symbol id replaces per-node type-name lookups.
const NodeClass = enum(u8) {
    none,
    pair,
    arguments,
    call_expression,
    type_key,
    import_export,
    jsx_attribute,
    jsx_element,
    object,
    scope_stop,
    template_substitution,
    attribute_name,
};

const class_by_name = std.StaticStringMap(NodeClass).initComptime(.{
    .{ "pair", .pair },
    .{ "arguments", .arguments },
    .{ "call_expression", .call_expression },
    .{ "property_signature", .type_key },
    .{ "method_signature", .type_key },
    .{ "enum_assignment", .type_key },
    .{ "import_statement", .import_export },
    .{ "export_statement", .import_export },
    .{ "jsx_attribute", .jsx_attribute },
    .{ "jsx_element", .jsx_element },
    .{ "jsx_self_closing_element", .jsx_element },
    .{ "object", .object },
    .{ "statement_block", .scope_stop },
    .{ "program", .scope_stop },
    .{ "template_substitution", .template_substitution },
    .{ "property_identifier", .attribute_name },
    .{ "identifier", .attribute_name },
    .{ "nested_identifier", .attribute_name },
});

/// The per-language hot-path pieces: a precompiled query that finds candidate
/// literal nodes, and a symbol-id to NodeClass table for cheap ancestor
/// classification.
pub const LangSupport = struct {
    language: *const ts.c.TSLanguage,
    query: ts.Query,
    /// Maps a query capture index to the literal kind it captures.
    kinds: []LiteralKind,
    classes: []NodeClass,

    const with_jsx = "(string) @string\n(template_string) @template\n(jsx_text) @jsxtext";
    const without_jsx = "(string) @string\n(template_string) @template";

    fn init(allocator: std.mem.Allocator, language: *const ts.c.TSLanguage) !LangSupport {
        // Grammars without JSX support (plain TypeScript) reject jsx_text.
        const query = ts.Query.init(language, with_jsx) catch
            try ts.Query.init(language, without_jsx);
        errdefer query.deinit();

        const capture_count = query.captureCount();
        const kinds = try allocator.alloc(LiteralKind, capture_count);
        errdefer allocator.free(kinds);
        for (0..capture_count) |i| {
            const name = query.captureNameForId(@intCast(i));
            kinds[i] = if (std.mem.eql(u8, name, "string"))
                .string
            else if (std.mem.eql(u8, name, "template"))
                .template
            else if (std.mem.eql(u8, name, "jsxtext"))
                .jsx_text
            else
                return error.UnexpectedCapture;
        }

        const symbol_count = ts.languageSymbolCount(language);
        const classes = try allocator.alloc(NodeClass, symbol_count);
        errdefer allocator.free(classes);
        for (0..symbol_count) |symbol| {
            const name = ts.languageSymbolName(language, @intCast(symbol));
            classes[symbol] = class_by_name.get(name) orelse .none;
        }

        return .{ .language = language, .query = query, .kinds = kinds, .classes = classes };
    }

    fn deinit(self: *LangSupport, allocator: std.mem.Allocator) void {
        self.query.deinit();
        allocator.free(self.kinds);
        allocator.free(self.classes);
    }

    fn classOf(self: *const LangSupport, node: ts.Node) NodeClass {
        const symbol: usize = node.symbol();
        if (symbol >= self.classes.len) return .none;
        return self.classes[symbol];
    }
};

/// Which grammar parses a given file.
pub const Kind = enum { typescript, tsx, javascript };

pub fn kindForPath(path: []const u8) Kind {
    const extension = gopath.ext(path);
    if (eqlIgnoreCase(extension, ".ts")) return .typescript;
    if (eqlIgnoreCase(extension, ".tsx") or eqlIgnoreCase(extension, ".jsx")) return .tsx;
    return .javascript;
}

/// The compiled grammars, shared by every worker: queries and languages are
/// immutable, while parsers and cursors are not, so each worker keeps its own.
///
/// Preparing one grammar compiles a query and walks its full symbol table, so
/// only the grammars the scan will actually reach are built. A project of plain
/// `.ts` files should not pay for the TSX and JavaScript grammars.
pub const Languages = struct {
    allocator: std.mem.Allocator,
    typescript: ?LangSupport = null,
    tsx: ?LangSupport = null,
    javascript: ?LangSupport = null,

    /// Prepares exactly the grammars `paths` needs.
    pub fn init(allocator: std.mem.Allocator, paths: []const []const u8) !Languages {
        var needed = [_]bool{false} ** @typeInfo(Kind).@"enum".fields.len;
        for (paths) |path| needed[@intFromEnum(kindForPath(path))] = true;

        var self = Languages{ .allocator = allocator };
        errdefer self.deinit();
        if (needed[@intFromEnum(Kind.typescript)]) {
            self.typescript = try LangSupport.init(allocator, ts.tree_sitter_typescript());
        }
        if (needed[@intFromEnum(Kind.tsx)]) {
            self.tsx = try LangSupport.init(allocator, ts.tree_sitter_tsx());
        }
        if (needed[@intFromEnum(Kind.javascript)]) {
            self.javascript = try LangSupport.init(allocator, ts.tree_sitter_javascript());
        }
        return self;
    }

    /// Prepares every grammar, for callers that do not know the paths up front.
    pub fn initAll(allocator: std.mem.Allocator) !Languages {
        return init(allocator, &.{ "a.ts", "a.tsx", "a.js" });
    }

    pub fn deinit(self: *Languages) void {
        if (self.typescript) |*support| support.deinit(self.allocator);
        if (self.tsx) |*support| support.deinit(self.allocator);
        if (self.javascript) |*support| support.deinit(self.allocator);
    }

    fn forPath(self: *const Languages, path: []const u8) ?*const LangSupport {
        return switch (kindForPath(path)) {
            .typescript => if (self.typescript) |*support| support else null,
            .tsx => if (self.tsx) |*support| support else null,
            .javascript => if (self.javascript) |*support| support else null,
        };
    }
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (gostd.toLower(x) != y) return false;
    }
    return true;
}

/// Per-worker parsing state. tree-sitter parsers and query cursors are not
/// thread-safe, so each worker owns one of each.
pub const Session = struct {
    parser: ts.Parser,
    cursor: ts.QueryCursor,

    pub fn init() !Session {
        const parser = try ts.Parser.init();
        errdefer parser.deinit();
        return .{ .parser = parser, .cursor = try ts.QueryCursor.init() };
    }

    pub fn deinit(self: *Session) void {
        self.parser.deinit();
        self.cursor.deinit();
    }
};

pub const ExtractError = anyerror;

/// Extracts every literal worth reporting from `content`.
///
/// A null `worth` keeps every literal; otherwise literals whose normalized form
/// fails the filter are dropped before the context checks run, because matching
/// against the index is a hash lookup while the context checks walk the
/// ancestor chain.
pub fn bytes(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    languages: *const Languages,
    session: *Session,
    path: []const u8,
    content: []const u8,
    min_length: usize,
    worth: ?MatchFunc,
) ExtractError![]Literal {
    const support = languages.forPath(path) orelse return error.LanguageNotPrepared;
    session.parser.setLanguage(support.language);
    const tree = try session.parser.parse(content);
    defer tree.deinit();

    const root = tree.rootNode();
    if (root.hasError()) return error.ParseError;

    var walker = Walker{
        .allocator = allocator,
        .scratch = scratch,
        .content = content,
        .min_length = min_length,
        .path = path,
        .lang = support,
        .worth = worth,
        .ignore_lines = try ignoreMarkerLines(allocator, content),
    };
    defer if (walker.ignore_lines) |lines| allocator.free(lines);
    errdefer walker.literals.deinit(allocator);

    session.cursor.exec(support.query, root);
    var captures: []const ts.Capture = &.{};
    while (session.cursor.nextMatch(&captures)) {
        for (captures) |capture| {
            if (capture.index >= support.kinds.len) continue;
            try walker.visit(support.kinds[capture.index], capture.node);
        }
    }

    const literals = try walker.literals.toOwnedSlice(allocator);
    // Query matches arrive in traversal order; sort to guarantee document order
    // for callers and tests.
    std.mem.sort(Literal, literals, {}, struct {
        fn lessThan(_: void, a: Literal, b: Literal) bool {
            if (a.line != b.line) return a.line < b.line;
            return a.column < b.column;
        }
    }.lessThan);
    return literals;
}

const Walker = struct {
    /// Owns the strings kept in `literals`.
    allocator: std.mem.Allocator,
    /// Holds the per-candidate work that is discarded again immediately.
    scratch: std.mem.Allocator,
    content: []const u8,
    min_length: usize,
    path: []const u8,
    lang: *const LangSupport,
    worth: ?MatchFunc,
    /// Marks zero-based rows that contain the inline ignore marker. Null when
    /// the marker is absent from the file (the common case).
    ignore_lines: ?[]bool,
    literals: std.ArrayList(Literal) = .empty,

    // Almost every literal in a file is rejected here, so the whole path runs on
    // the scratch allocator and borrows rather than copies wherever it can. Only
    // a literal that survives every check is copied into `allocator`.
    fn visit(self: *Walker, kind: LiteralKind, node: ts.Node) !void {
        var raw = gostd.Text.borrow("");
        defer raw.deinit(self.scratch);
        switch (kind) {
            .string => raw = (try decodeQuoted(self.scratch, node.content(self.content))) orelse return,
            .template => {
                if (self.hasSubstitution(node)) return;
                raw = (try decodeTemplate(self.scratch, node.content(self.content))) orelse return;
            },
            .jsx_text => raw = .borrow(trimSpace(node.content(self.content))),
        }
        // Collapse whitespace once and reuse it for the length check, the
        // stored literal and the normalized form.
        const collapsed = try normalize.collapse(self.scratch, raw.bytes);
        defer collapsed.deinit(self.scratch);
        if (normalize.gateLength(collapsed.bytes) < self.min_length) return;
        const normalized = try gostd.toLowerText(self.scratch, collapsed.bytes);
        defer normalized.deinit(self.scratch);
        if (normalized.bytes.len == 0) return;
        // The worth filter runs before the context checks: matching against the
        // index is a hash lookup, while the context checks walk the ancestor
        // chain, so uninteresting literals never pay for that walk.
        if (self.worth) |filter| {
            if (!try filter.worth(normalized.bytes)) return;
        }
        if (kind == .string and !self.shouldScanString(node)) return;
        const point = node.startPoint();
        if (self.hasInlineIgnore(point.row)) return;
        try self.literals.append(self.allocator, .{
            .file = self.path,
            .line = @as(usize, point.row) + 1,
            .column = @as(usize, point.column) + 1,
            .literal = try self.allocator.dupe(u8, collapsed.bytes),
            .normalized_literal = try self.allocator.dupe(u8, normalized.bytes),
        });
    }

    fn hasInlineIgnore(self: *const Walker, zero_based_row: u32) bool {
        const lines = self.ignore_lines orelse return false;
        const row: usize = zero_based_row;
        if (row < lines.len and lines[row]) return true;
        if (row > 0 and row - 1 < lines.len and lines[row - 1]) return true;
        return false;
    }

    /// Applies all context filters (object keys, type literal keys,
    /// import/export sources, require() arguments, JSX attributes) in a single
    /// walk up the ancestor chain.
    ///
    /// Rejection filters take precedence over the JSX attribute visibility
    /// check: each filter scans upward until its own stop node, independent of
    /// the others.
    fn shouldScanString(self: *const Walker, node: ts.Node) bool {
        const parent = node.parent() orelse return true;
        switch (self.lang.classOf(parent)) {
            .pair => {
                if (parent.childByFieldName("key")) |key| {
                    if (key.eql(node)) return false;
                }
            },
            .arguments => {
                if (parent.parent()) |call| {
                    if (self.lang.classOf(call) == .call_expression) {
                        if (call.childByFieldName("function")) |function| {
                            if (std.mem.eql(u8, function.content(self.content), "require")) return false;
                        }
                    }
                }
            },
            else => {},
        }

        // Active flags track which filters are still scanning; each filter
        // stops at its own boundary node types.
        var type_key_active = true;
        var import_active = true;
        var jsx_active = true;
        var jsx_attribute: ?ts.Node = null;
        var p: ?ts.Node = parent;
        while (p) |current| : (p = current.parent()) {
            switch (self.lang.classOf(current)) {
                .type_key => if (type_key_active) return false,
                .import_export => if (import_active) return false,
                .jsx_attribute => {
                    if (jsx_active) {
                        jsx_attribute = current;
                        jsx_active = false;
                    }
                },
                .jsx_element => jsx_active = false,
                .object => type_key_active = false,
                .scope_stop => {
                    type_key_active = false;
                    import_active = false;
                    jsx_active = false;
                },
                else => {},
            }
            if (!type_key_active and !import_active and !jsx_active) break;
        }
        if (jsx_attribute) |attribute| return self.isVisibleJSXAttribute(attribute);
        return true;
    }

    fn isVisibleJSXAttribute(self: *const Walker, attribute: ts.Node) bool {
        var name: []const u8 = "";
        var i: u32 = 0;
        const count = attribute.childCount();
        while (i < count) : (i += 1) {
            const child = attribute.child(i) orelse continue;
            if (self.lang.classOf(child) == .attribute_name) {
                name = child.content(self.content);
                break;
            }
        }
        const visible = [_][]const u8{ "aria-label", "title", "placeholder", "alt", "label" };
        for (visible) |candidate| {
            if (std.mem.eql(u8, name, candidate)) return true;
        }
        return false;
    }

    fn hasSubstitution(self: *const Walker, node: ts.Node) bool {
        var i: u32 = 0;
        const count = node.childCount();
        while (i < count) : (i += 1) {
            const child = node.child(i) orelse continue;
            if (self.lang.classOf(child) == .template_substitution) return true;
        }
        return false;
    }
};

/// Scans the file once and records which rows contain the inline ignore marker.
/// Returns null when the marker is absent so the per-literal check is a no-op
/// instead of re-splitting the file.
fn ignoreMarkerLines(allocator: std.mem.Allocator, content: []const u8) !?[]bool {
    if (std.mem.indexOf(u8, content, ignore_marker) == null) return null;
    var lines: std.ArrayList(bool) = .empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        try lines.append(allocator, std.mem.indexOf(u8, line, ignore_marker) != null);
    }
    return try lines.toOwnedSlice(allocator);
}

/// strings.TrimSpace.
pub fn trimSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const r = gostd.decodeRune(s[start..]);
        if (!gostd.isSpace(r.value)) break;
        start += r.size;
    }
    var end = s.len;
    while (end > start) {
        const r = gostd.decodeLastRune(s[start..end]);
        if (!gostd.isSpace(r.value)) break;
        end -= r.size;
    }
    return s[start..end];
}

fn decodeQuoted(allocator: std.mem.Allocator, raw: []const u8) !?gostd.Text {
    if (raw.len < 2) return null;
    const quote = raw[0];
    if (quote != '\'' and quote != '"') return null;
    return try unquoteJS(allocator, raw[1 .. raw.len - 1], quote);
}

fn decodeTemplate(allocator: std.mem.Allocator, raw: []const u8) !?gostd.Text {
    if (raw.len < 2 or raw[0] != '`' or raw[raw.len - 1] != '`') return null;
    return try unquoteJS(allocator, raw[1 .. raw.len - 1], '`');
}

/// Decodes JavaScript escape sequences, borrowing the input when it holds no
/// escapes. Anything Go's strconv would reject leaves the text untouched, which
/// is what the original does.
pub fn unquoteJS(allocator: std.mem.Allocator, value: []const u8, quote: u8) !gostd.Text {
    if (std.mem.indexOfScalar(u8, value, '\\') == null) return .borrow(value);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, value.len);
    var rest = value;
    while (rest.len > 0) {
        const decoded = gostd.unquoteChar(rest, quote) orelse {
            out.deinit(allocator);
            return .borrow(value);
        };
        var buf: [4]u8 = undefined;
        try out.appendSlice(allocator, gostd.encodeRune(&buf, decoded.value));
        rest = decoded.tail;
    }
    return .own(try out.toOwnedSlice(allocator));
}
