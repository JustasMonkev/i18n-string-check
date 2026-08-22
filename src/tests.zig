//! The test suite. `zig build test` runs everything referenced from here.

const std = @import("std");

const extract = @import("extract.zig");
const fastscan = @import("fastscan.zig");
const gopath = @import("gopath.zig");
const gostd = @import("gostd.zig");
const i18nindex = @import("index.zig");
const normalize = @import("normalize.zig");
const report = @import("report.zig");
const scan = @import("scan.zig");

comptime {
    _ = @import("index.zig");
}

const testing = std.testing;

// -- normalize ---------------------------------------------------------------

test "normalize trims and lowercases" {
    const got = try normalize.normalize(testing.allocator, "  SIGN IN  ");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("sign in", got);
}

test "normalize collapses whitespace" {
    const got = try normalize.normalize(testing.allocator, "Hello\n\t  world");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello world", got);
}

test "normalize handles unicode case" {
    const got = try normalize.normalize(testing.allocator, "CAFÉ");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("café", got);
}

test "trimmedLength" {
    try testing.expectEqual(@as(usize, 2), try normalize.trimmedLength(testing.allocator, "  OK  "));
}

test "trimmedLength counts space-separated phrases conservatively" {
    try testing.expectEqual(@as(usize, 8), try normalize.trimmedLength(testing.allocator, "Sign in"));
}

test "trimmedLength collapses whitespace before counting" {
    try testing.expectEqual(@as(usize, 8), try normalize.trimmedLength(testing.allocator, "Sign\n\t  in"));
}

test "collapseWhitespace leaves clean input alone" {
    const got = try normalize.collapseWhitespace(testing.allocator, "already clean text");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("already clean text", got);
}

test "collapseWhitespace leaves malformed utf-8 alone when nothing needs collapsing" {
    const got = try normalize.collapseWhitespace(testing.allocator, "bad \xff byte");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("bad \xff byte", got);
}

test "collapseWhitespace replaces malformed utf-8 when it rebuilds the string" {
    const got = try normalize.collapseWhitespace(testing.allocator, "bad  \xff  byte");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("bad \u{FFFD} byte", got);
}

// -- Go primitives -----------------------------------------------------------

test "decodeRune matches Go for malformed input" {
    // A lone continuation byte advances exactly one byte.
    const bad = gostd.decodeRune("\x80rest");
    try testing.expectEqual(gostd.rune_error, bad.value);
    try testing.expectEqual(@as(usize, 1), bad.size);

    // Surrogates and overlong encodings are rejected.
    try testing.expectEqual(gostd.rune_error, gostd.decodeRune("\xed\xa0\x80").value);
    try testing.expectEqual(gostd.rune_error, gostd.decodeRune("\xc0\xaf").value);

    const ok = gostd.decodeRune("é");
    try testing.expectEqual(@as(u21, 0xE9), ok.value);
    try testing.expectEqual(@as(usize, 2), ok.size);
}

test "quote matches strconv.Quote" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "Sign in", .want = "\"Sign in\"" },
        .{ .in = "café", .want = "\"café\"" },
        .{ .in = "has \"quotes\"", .want = "\"has \\\"quotes\\\"\"" },
        .{ .in = "back\\slash", .want = "\"back\\\\slash\"" },
        .{ .in = "tab\there", .want = "\"tab\\there\"" },
        .{ .in = "bell\x07", .want = "\"bell\\a\"" },
        // A zero-width joiner is a format character, so Go escapes it.
        .{ .in = "zwj\u{200d}", .want = "\"zwj\\u200d\"" },
        // Emoji are symbols, so they stay literal.
        .{ .in = "rocket🚀", .want = "\"rocket🚀\"" },
        .{ .in = "cjk世界", .want = "\"cjk世界\"" },
    };
    for (cases) |c| {
        const got = try gostd.quote(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "appendJSONString escapes like encoding/json" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "plain", .want = "\"plain\"" },
        .{ .in = "<a> & <b>", .want = "\"\\u003ca\\u003e \\u0026 \\u003cb\\u003e\"" },
        .{ .in = "line\nbreak", .want = "\"line\\nbreak\"" },
        .{ .in = "bell\x07", .want = "\"bell\\u0007\"" },
        .{ .in = "café", .want = "\"café\"" },
        .{ .in = "sep\u{2028}here", .want = "\"sep\\u2028here\"" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try gostd.appendJSONString(testing.allocator, &out, c.in);
        try testing.expectEqualStrings(c.want, out.items);
    }
}

test "appendJSONFloat matches encoding/json" {
    const cases = [_]struct { in: f64, want: []const u8 }{
        .{ .in = 1, .want = "1" },
        .{ .in = 0.8181818181818182, .want = "0.8181818181818182" },
        .{ .in = 0.8888888888888888, .want = "0.8888888888888888" },
        .{ .in = 0.7142857142857143, .want = "0.7142857142857143" },
        .{ .in = 1e-7, .want = "1e-7" },
        .{ .in = 1e21, .want = "1e+21" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try gostd.appendJSONFloat(testing.allocator, &out, c.in);
        try testing.expectEqualStrings(c.want, out.items);
    }
}

test "toLowerString folds unicode per rune" {
    const got = try gostd.toLowerString(testing.allocator, "STRASSE Ärger ÅNGSTRÖM");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("strasse ärger ångström", got);
}

// -- gopath ------------------------------------------------------------------

test "clean matches filepath.Clean" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "", .want = "." },
        .{ .in = "./src", .want = "src" },
        .{ .in = "src//a/../b", .want = "src/b" },
        .{ .in = "../../a", .want = "../../a" },
        .{ .in = "/a/b/../c/", .want = "/a/c" },
        .{ .in = "/../a", .want = "/a" },
    };
    for (cases) |c| {
        const got = try gopath.clean(testing.allocator, c.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "rel matches filepath.Rel" {
    const got = try gopath.rel(testing.allocator, "/a/b", "/a/b/c/d.ts");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("c/d.ts", got);

    const up = try gopath.rel(testing.allocator, "/a/b/c", "/a/x");
    defer testing.allocator.free(up);
    try testing.expectEqualStrings("../../x", up);

    // A relative target cannot be expressed against an absolute base.
    try testing.expectError(error.CannotRelate, gopath.rel(testing.allocator, "/a", "b"));
}

test "match matches filepath.Match" {
    try testing.expect(gopath.match("*.ts", "a.ts"));
    try testing.expect(!gopath.match("*.ts", "dir/a.ts"));
    try testing.expect(gopath.match("dir/*.ts", "dir/a.ts"));
    try testing.expect(gopath.match("a?c", "abc"));
    try testing.expect(gopath.match("[abc]d", "bd"));
    try testing.expect(!gopath.match("[^abc]d", "bd"));
    // A malformed pattern is reported as no match, as the callers expect.
    try testing.expect(!gopath.match("[abc", "a"));
}

test "ext matches filepath.Ext" {
    try testing.expectEqualStrings(".ts", gopath.ext("a/b.ts"));
    try testing.expectEqualStrings(".tsx", gopath.ext("a.b.tsx"));
    try testing.expectEqualStrings("", gopath.ext("a/b"));
    try testing.expectEqualStrings("", gopath.ext("a.d/b"));
}

// -- index -------------------------------------------------------------------

fn loadIndex(source: []const u8, min_length: usize) !*i18nindex.Index {
    return i18nindex.fromBytes(testing.allocator, source, min_length);
}

test "index creation and lookup" {
    var idx = try loadIndex(
        \\{"login.button":"Sign in","common.cancel":"Cancel"}
    , 8);
    defer idx.deinit();

    const normalized = try normalize.normalize(testing.allocator, "sign in");
    defer testing.allocator.free(normalized);
    const matches = idx.lookupNormalized(normalized);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("login.button", matches[0].key);
    try testing.expectEqualStrings("Sign in", matches[0].value);
}

test "duplicate values map to multiple keys" {
    var idx = try loadIndex(
        \\{"common.save":"Save","profile.save":"Save"}
    , 1);
    defer idx.deinit();

    const normalized = try normalize.normalize(testing.allocator, "SAVE");
    defer testing.allocator.free(normalized);
    try testing.expectEqual(@as(usize, 2), idx.lookupNormalized(normalized).len);
}

test "hasExactValue" {
    const matches = [_]i18nindex.Match{
        .{ .key = "login.button", .value = "sign in" },
        .{ .key = "login.heading", .value = "Sign In" },
    };
    try testing.expect(i18nindex.hasExactValue(&matches, "sign in"));
    try testing.expect(!i18nindex.hasExactValue(&matches, "Sign in"));
}

fn lookupSimilar(idx: *i18nindex.Index, arena: std.mem.Allocator, value: []const u8) ![]i18nindex.Match {
    var scratch = try i18nindex.SimScratch.init(testing.allocator, idx);
    defer scratch.deinit();
    const normalized = try normalize.normalize(arena, value);
    return idx.lookupSimilarNormalized(arena, testing.allocator, &scratch, normalized);
}

test "lookupSimilar finds a likely previous translation value" {
    var idx = try loadIndex(
        \\{"login.title":"Hello my name is Justas, And I am Human, I am QA too"}
    , 8);
    defer idx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const matches = try lookupSimilar(idx, arena.allocator(), "Hello my name is Justas, And I am Human");
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("login.title", matches[0].key);
    try testing.expect(matches[0].detail.score >= 0.8);
    try testing.expectEqualStrings(
        "source string is contained in the current translation value; 82% word overlap",
        matches[0].detail.why,
    );
}

test "lookupSimilar uses edit similarity for small word changes" {
    var idx = try loadIndex(
        \\{"dashboard.title":"Review consumer billing dashbord status today"}
    , 8);
    defer idx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const matches = try lookupSimilar(idx, arena.allocator(), "Review customer billing dashboard status today");
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("dashboard.title", matches[0].key);
    try testing.expectEqualStrings("edit-similarity", matches[0].detail.reason);
}

test "lookupSimilar ignores short different strings" {
    var idx = try loadIndex(
        \\{"login.button":"Log in"}
    , 8);
    defer idx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectEqual(@as(usize, 0), (try lookupSimilar(idx, arena.allocator(), "Sign in")).len);
}

test "lookupSimilar finds a match in a large unrelated index" {
    var idx = try loadIndex(
        \\{
        \\  "noise.1": "The deployment pipeline finished without errors this morning",
        \\  "noise.2": "Customers can export invoices from the billing settings page",
        \\  "noise.3": "Administrators may revoke access tokens from user profiles",
        \\  "login.title": "Hello my name is Justas, And I am Human, I am QA too"
        \\}
    , 8);
    defer idx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const matches = try lookupSimilar(idx, arena.allocator(), "Hello my name is Justas, And I am Human");
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("login.title", matches[0].key);
}

test "short values are ignored" {
    var idx = try loadIndex(
        \\{"short.ok":"OK"}
    , 8);
    defer idx.deinit();
    const normalized = try normalize.normalize(testing.allocator, "OK");
    defer testing.allocator.free(normalized);
    try testing.expectEqual(@as(usize, 0), idx.lookupNormalized(normalized).len);
}

test "nested objects flatten to dot keys" {
    var idx = try loadIndex(
        \\{"login":{"button":"Sign in","title":"Welcome back"},"common":{"actions":{"save":"Save changes"}}}
    , 1);
    defer idx.deinit();

    const cases = [_]struct { value: []const u8, key: []const u8 }{
        .{ .value = "Sign in", .key = "login.button" },
        .{ .value = "Welcome back", .key = "login.title" },
        .{ .value = "Save changes", .key = "common.actions.save" },
    };
    for (cases) |c| {
        const normalized = try normalize.normalize(testing.allocator, c.value);
        defer testing.allocator.free(normalized);
        const matches = idx.lookupNormalized(normalized);
        try testing.expectEqual(@as(usize, 1), matches.len);
        try testing.expectEqualStrings(c.key, matches[0].key);
    }
}

test "interpolation patterns match filled-in literals" {
    var idx = try loadIndex(
        \\{"profile.greeting":"Hello, {name}"}
    , 8);
    defer idx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const normalized = try normalize.normalize(a, "Hello, Bob");
    const matches = try idx.lookupPatternNormalized(a, a, normalized);
    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqualStrings("profile.greeting", matches[0].key);

    // The placeholder must consume at least one character.
    const empty = try normalize.normalize(a, "Hello, ");
    try testing.expectEqual(@as(usize, 0), (try idx.lookupPatternNormalized(a, a, empty)).len);
}

test "plural patterns match each category arm" {
    var idx = try loadIndex(
        \\{"invite":"{count, plural, one {# invite} other {# invites}}"}
    , 8);
    defer idx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{ "3 invites", "1 invite" }) |value| {
        const normalized = try normalize.normalize(a, value);
        const matches = try idx.lookupPatternNormalized(a, a, normalized);
        try testing.expectEqual(@as(usize, 1), matches.len);
        try testing.expectEqualStrings("invite", matches[0].key);
    }
    // The digits placeholder only accepts digits.
    const bad = try normalize.normalize(a, "many invites");
    try testing.expectEqual(@as(usize, 0), (try idx.lookupPatternNormalized(a, a, bad)).len);
}

test "bare placeholders do not become patterns" {
    // "{count}" has no literal characters, so it must not match everything.
    var idx = try loadIndex(
        \\{"bare":"{count}","short":"ab {x}"}
    , 1);
    defer idx.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const normalized = try normalize.normalize(a, "anything at all");
    try testing.expectEqual(@as(usize, 0), (try idx.lookupPatternNormalized(a, a, normalized)).len);
}

test "malformed translations are rejected" {
    try testing.expectError(error.MalformedTranslations, loadIndex("{not json", 8));
}

test "repeated keys keep the last value" {
    var idx = try loadIndex(
        \\{"a":"Sign in now please","a":"Save changes now please"}
    , 8);
    defer idx.deinit();

    const last = try normalize.normalize(testing.allocator, "Save changes now please");
    defer testing.allocator.free(last);
    try testing.expectEqual(@as(usize, 1), idx.lookupNormalized(last).len);

    const first = try normalize.normalize(testing.allocator, "Sign in now please");
    defer testing.allocator.free(first);
    try testing.expectEqual(@as(usize, 0), idx.lookupNormalized(first).len);
}

// -- extract -----------------------------------------------------------------

const Extracted = struct {
    arena: std.heap.ArenaAllocator,
    languages: extract.Languages,
    session: extract.Session,
    literals: []extract.Literal,

    fn deinit(self: *Extracted) void {
        self.session.deinit();
        self.languages.deinit();
        self.arena.deinit();
    }
};

fn extractSource(name: []const u8, source: []const u8, min_length: usize) !Extracted {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    var languages = try extract.Languages.init(testing.allocator);
    errdefer languages.deinit();
    var session = try extract.Session.init();
    errdefer session.deinit();
    const literals = try extract.bytes(
        arena.allocator(),
        &languages,
        &session,
        name,
        source,
        min_length,
        null,
    );
    return .{ .arena = arena, .languages = languages, .session = session, .literals = literals };
}

fn expectOneLiteral(name: []const u8, source: []const u8, want: []const u8) !void {
    var result = try extractSource(name, source, 8);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.literals.len);
    try testing.expectEqualStrings(want, result.literals[0].literal);
}

fn expectNoLiterals(name: []const u8, source: []const u8) !void {
    var result = try extractSource(name, source, 8);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.literals.len);
}

test "hardcoded string is extracted" {
    try expectOneLiteral("component.tsx", "const label = \"Sign in\";", "Sign in");
}

test "test assertion string is extracted" {
    try expectOneLiteral("login.spec.ts", "await expect(button).toHaveText(\"Sign in\");", "Sign in");
}

test "translation key is extracted but will not match translation values" {
    try expectOneLiteral("component.tsx", "const label = t(\"login.button\");", "login.button");
}

test "short string ignored" {
    try expectNoLiterals("short.ts", "const label = \"OK\";");
}

test "dynamic template skipped" {
    try expectNoLiterals("template.tsx", "const label = `Sign in ${name}`;");
}

test "static template extracted" {
    try expectOneLiteral("template.tsx", "const label = `Sign in`;", "Sign in");
}

test "case variant extracted with normalized value" {
    var result = try extractSource("case.tsx", "const label = \"SIGN IN\";", 8);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.literals.len);
    try testing.expectEqualStrings("SIGN IN", result.literals[0].literal);
    try testing.expectEqualStrings("sign in", result.literals[0].normalized_literal);
}

test "import path ignored" {
    try expectNoLiterals("import_path.ts", "import thing from \"Sign in\";");
}

test "require path ignored" {
    try expectNoLiterals("require_path.js", "const thing = require(\"Sign in\");");
}

test "object key ignored" {
    try expectNoLiterals("object_key.ts", "const labels = {\"Sign in\": true};");
}

test "type literal key ignored" {
    try expectNoLiterals("type_literal.ts", "type Labels = {\"Sign in\": string};");
}

test "jsx text extracted" {
    try expectOneLiteral(
        "component.tsx",
        "export function View() { return <button>Sign in</button>; }",
        "Sign in",
    );
}

test "jsx text whitespace collapsed" {
    try expectOneLiteral(
        "component.tsx",
        "export function View() { return <p>Hello\n  world</p>; }",
        "Hello world",
    );
}

test "jsx visible attribute extracted" {
    try expectOneLiteral(
        "component.tsx",
        "export function View() { return <input placeholder=\"Sign in\" />; }",
        "Sign in",
    );
}

test "jsx non-visible attribute ignored" {
    try expectNoLiterals(
        "component.tsx",
        "export function View() { return <input data-testid=\"Sign in\" />; }",
    );
}

test "jsx non-visible expression attribute ignored" {
    try expectNoLiterals(
        "component.tsx",
        "export function View() { return <input data-testid={\"Sign in\"} />; }",
    );
}

test "inline ignore marker suppresses the literal" {
    try expectNoLiterals("login.ts", "// i18n-string-check-ignore\nconst label = \"Sign in\";");
    try expectNoLiterals("login.ts", "const label = \"Sign in\"; // i18n-string-check-ignore");
}

test "parse errors are reported" {
    var languages = try extract.Languages.init(testing.allocator);
    defer languages.deinit();
    var session = try extract.Session.init();
    defer session.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.ParseError, extract.bytes(
        arena.allocator(),
        &languages,
        &session,
        "bad.ts",
        "const label = \"Sign in\" @@@ ;;;",
        8,
        null,
    ));
}

test "literals are returned in document order" {
    var result = try extractSource("many.tsx",
        \\const a = "First literal here";
        \\const b = "Second literal here";
        \\const c = "Third literal here";
    , 8);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 3), result.literals.len);
    try testing.expectEqual(@as(usize, 1), result.literals[0].line);
    try testing.expectEqual(@as(usize, 2), result.literals[1].line);
    try testing.expectEqual(@as(usize, 3), result.literals[2].line);
}

test "escape sequences are decoded" {
    var result = try extractSource("esc.ts", "const a = \"It\\u0027s time to sign in\";", 8);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.literals.len);
    try testing.expectEqualStrings("It's time to sign in", result.literals[0].literal);
}

test "trimSpace matches strings.TrimSpace" {
    try testing.expectEqualStrings("a b", extract.trimSpace("  \t\n a b \r\n "));
    try testing.expectEqualStrings("", extract.trimSpace("   "));
    try testing.expectEqualStrings("é", extract.trimSpace(" é "));
    // U+00A0 is whitespace to unicode.IsSpace, so it is trimmed.
    try testing.expectEqualStrings("x", extract.trimSpace("\u{00A0}x\u{00A0}"));
}

// -- fastscan ----------------------------------------------------------------

const Collector = struct {
    allocator: std.mem.Allocator,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// When set, the filter reports a match for this exact candidate.
    wanted: ?[]const u8 = null,

    fn matchFunc(self: *Collector) extract.MatchFunc {
        return .{ .ctx = self, .call = call };
    }

    fn call(ctx: *anyopaque, normalized: []const u8) anyerror!bool {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        try self.seen.put(self.allocator, try self.allocator.dupe(u8, normalized), {});
        if (self.wanted) |wanted| return std.mem.eql(u8, normalized, wanted);
        return false;
    }
};

fn collectCandidates(
    arena: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    min_length: usize,
) !Collector {
    var collector = Collector{ .allocator = arena };
    _ = try fastscan.hasCandidateMatch(arena, path, source, min_length, collector.matchFunc());
    return collector;
}

// The load-bearing property: every literal the full parser extracts must also
// surface as a fast-scan candidate, otherwise the pre-scan could skip files
// that have findings.
test "fast scan covers extracted literals" {
    const sources = [_]struct { path: []const u8, source: []const u8 }{
        .{ .path = "strings.ts", .source =
        \\const a = "Sign in to your account";
        \\const b = 'It\'s time to sign in';
        \\const c = "He said \"hello\" to everyone";
        \\const tpl = `Your report is ready`;
        \\const nested = `head ${`Inner template text here`} tail`;
        \\const priceTpl = `cost \${amount} dollars today`;
        },
        .{ .path = "component.tsx", .source =
        \\export function View() {
        \\  return (
        \\    <div title="Changes were saved automatically">
        \\      <p>Don't worry about a thing</p>
        \\      <p>Hello
        \\        world spanning lines</p>
        \\      <input placeholder="Enter your email address" />
        \\      <span>{'Braced expression string'}</span>
        \\    </div>
        \\  );
        \\}
        },
        .{ .path = "mixed.jsx", .source =
        \\const re = "no regex here";
        \\export const V = () => <p>Apostrophes don't break scanning</p>;
        \\const after = "String after the JSX text";
        },
    };

    for (sources) |entry| {
        var result = try extractSource(entry.path, entry.source, 8);
        defer result.deinit();
        try testing.expect(result.literals.len > 0);

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var collector = try collectCandidates(arena.allocator(), entry.path, entry.source, 8);
        for (result.literals) |literal| {
            if (!collector.seen.contains(literal.normalized_literal)) {
                std.debug.print("{s}: extracted literal \"{s}\" missing from fast-scan candidates\n", .{
                    entry.path, literal.normalized_literal,
                });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "fast scan skips substitution templates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var collector = try collectCandidates(
        arena.allocator(),
        "t.ts",
        "const a = `Sign in ${name} now please`;",
        8,
    );
    try testing.expect(!collector.seen.contains("sign in ${name} now please"));
}

test "fast scan honors min length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var collector = try collectCandidates(arena.allocator(), "t.ts", "const a = \"short\";", 8);
    try testing.expectEqual(@as(usize, 0), collector.seen.count());
}

test "fast scan normalizes candidates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var collector = try collectCandidates(
        arena.allocator(),
        "t.tsx",
        "const a = \"SIGN IN\tNOW  Please\";",
        8,
    );
    try testing.expect(collector.seen.contains("sign in now please"));
}

test "fast scan handles non-ascii candidates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var collector = try collectCandidates(
        arena.allocator(),
        "t.ts",
        "const a = \"Zeichenkette mit Ümlauten größer\";",
        8,
    );
    try testing.expect(collector.seen.contains("zeichenkette mit ümlauten größer"));
}

// Plain .ts parses with the JSX-free grammar, so bare text between angle
// brackets can never be a literal and must not become a candidate.
test "fast scan skips jsx runs for plain typescript" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var collector = try collectCandidates(
        arena.allocator(),
        "t.ts",
        "const ok = 1 < 2;\nlet fine = true; // Sign in to your account maybe > not text\n",
        8,
    );
    try testing.expect(!collector.seen.contains("sign in to your account maybe"));
}

test "fast scan reports a match" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source = "const a = \"Sign in to your account\";";

    var hit = Collector{ .allocator = arena.allocator(), .wanted = "sign in to your account" };
    try testing.expect(try fastscan.hasCandidateMatch(
        arena.allocator(),
        "t.ts",
        source,
        8,
        hit.matchFunc(),
    ));

    var miss = Collector{ .allocator = arena.allocator() };
    try testing.expect(!try fastscan.hasCandidateMatch(
        arena.allocator(),
        "t.ts",
        source,
        8,
        miss.matchFunc(),
    ));
}

// -- scan --------------------------------------------------------------------

const TempTree = struct {
    dir: std.Io.Dir,
    path: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,

    fn deinit(self: *TempTree) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.dir.close(self.io);
        self.allocator.free(self.path);
    }

    fn write(self: *TempTree, name: []const u8, content: []const u8) !void {
        if (std.fs.path.dirname(name)) |parent| {
            try self.dir.createDirPath(self.io, parent);
        }
        try self.dir.writeFile(self.io, .{ .sub_path = name, .data = content });
    }
};

fn tempTree(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !TempTree {
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/test-{s}", .{name});
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
    try std.Io.Dir.cwd().createDirPath(io, path);
    const dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    return .{ .dir = dir, .path = path, .io = io, .allocator = allocator };
}

test "discoverFiles filters extensions and excludes" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tree = try tempTree(a, io, "discover");
    defer tree.deinit();
    try tree.write("src/a.ts", "");
    try tree.write("src/b.go", "");
    try tree.write("node_modules/c.ts", "");
    try tree.write("custom/d.tsx", "");

    const files = try scan.discoverFiles(a, io, tree.path, .{
        .extensions = &.{"ts"},
        .exclude = &.{"custom"},
    });
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("a.ts", gopath.base(files[0]));
}

test "discoverFiles skips symlinked files" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tree = try tempTree(a, io, "symlink");
    defer tree.deinit();
    try tree.write("src/a.ts", "");
    try tree.write("outside.ts", "");
    tree.dir.symLink(io, "../outside.ts", "src/leak.ts", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    const root = try std.fmt.allocPrint(a, "{s}/src", .{tree.path});
    const files = try scan.discoverFiles(a, io, root, .{});
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("a.ts", gopath.base(files[0]));
}

test "discoverFiles sorts results" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tree = try tempTree(a, io, "sorted");
    defer tree.deinit();
    for ([_][]const u8{ "z.ts", "a.ts", "m/b.ts", "m/a.ts" }) |name| try tree.write(name, "");

    const files = try scan.discoverFiles(a, io, tree.path, .{});
    try testing.expectEqual(@as(usize, 4), files.len);
    for (files[1..], files[0 .. files.len - 1]) |next, previous| {
        try testing.expect(std.mem.order(u8, previous, next) == .lt);
    }
}

// -- report ------------------------------------------------------------------

fn renderText(allocator: std.mem.Allocator, findings: []report.Finding) ![]const u8 {
    const summary = try report.newSummary(allocator, findings);
    var out: std.ArrayList(u8) = .empty;
    try report.writeText(allocator, &out, summary);
    return out.items;
}

fn expectContainsAll(text: []const u8, wants: []const []const u8) !void {
    for (wants) |want| {
        if (std.mem.indexOf(u8, text, want) == null) {
            std.debug.print("output missing \"{s}\":\n{s}\n", .{ want, text });
            return error.TestUnexpectedResult;
        }
    }
}

test "text output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var findings = [_]report.Finding{.{
        .file = "tests/login.spec.ts",
        .line = 42,
        .column = 18,
        .type = "hardcoded-translation",
        .literal = "Sign in",
        .normalized_literal = "sign in",
        .matches = &.{.{ .key = "login.button", .value = "Sign in" }},
    }};
    const text = try renderText(arena.allocator(), &findings);
    try expectContainsAll(text, &.{
        "hardcoded translation: tests/login.spec.ts:42",
        "literal: \"Sign in\"",
        "matches en.json key: \"login.button\" value: \"Sign in\"",
        "1 i18n issues found in 1 files",
    });
}

test "text output with multiple keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var findings = [_]report.Finding{.{
        .file = "src/Button.tsx",
        .line = 12,
        .column = 8,
        .type = "hardcoded-translation",
        .literal = "Save",
        .normalized_literal = "save",
        .matches = &.{
            .{ .key = "common.save", .value = "Save" },
            .{ .key = "profile.save", .value = "Save" },
        },
    }};
    const text = try renderText(arena.allocator(), &findings);
    try expectContainsAll(text, &.{
        "matches multiple en.json keys:",
        "- \"common.save\" value: \"Save\"",
        "- \"profile.save\" value: \"Save\"",
        "fix: replace with the correct t(\"...\") key for this context",
    });
}

test "text output for a test value mismatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var findings = [_]report.Finding{.{
        .file = "tests/login.spec.ts",
        .line = 42,
        .column = 18,
        .type = "test-value-mismatch",
        .literal = "Sign in",
        .normalized_literal = "sign in",
        .matches = &.{.{ .key = "login.button", .value = "sign in" }},
    }};
    const text = try renderText(arena.allocator(), &findings);
    try expectContainsAll(text, &.{
        "translation value mismatch: tests/login.spec.ts:42",
        "literal: \"Sign in\"",
        "matches en.json key: \"login.button\" value: \"sign in\"",
        "fix: update the test literal to the current en.json value for \"login.button\"",
    });
}

test "text output for a likely stale hardcoded translation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var findings = [_]report.Finding{.{
        .file = "src/Login.tsx",
        .line = 12,
        .column = 8,
        .type = "changed-translation-value",
        .literal = "Hello my name is Justas, And I am Human",
        .normalized_literal = "hello my name is justas, and i am human",
        .matches = &.{.{
            .key = "login.title",
            .value = "Hello my name is Justas, And I am Human, I am QA too",
            .detail = .{
                .score = 0.82,
                .why = "source string is contained in the current translation value; 82% word overlap",
            },
        }},
    }};
    const text = try renderText(arena.allocator(), &findings);
    try expectContainsAll(text, &.{
        "likely stale hardcoded translation: src/Login.tsx:12",
        "  current code string:",
        "    \"Hello my name is Justas, And I am Human\"",
        "  similar en.json value:",
        "    key: \"login.title\"",
        "    value: \"Hello my name is Justas, And I am Human, I am QA too\"",
        "  similarity: 82%",
        "  why: source string is contained in the current translation value; 82% word overlap",
        "  fix: replace with t(\"login.title\"), or mark this literal intentional",
    });
}

test "json output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var findings = [_]report.Finding{.{
        .file = "tests/login.spec.ts",
        .line = 42,
        .column = 18,
        .type = "hardcoded-translation",
        .literal = "Sign in",
        .normalized_literal = "sign in",
        .matches = &.{.{ .key = "login.button", .value = "Sign in" }},
    }};
    const summary = try report.newSummary(a, &findings);
    var out: std.ArrayList(u8) = .empty;
    try report.writeJSON(a, &out, summary);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, out.items, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("found").?.bool);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("count").?.integer);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("files").?.integer);
}

test "json output distinguishes an absent findings list from an empty one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var absent: std.ArrayList(u8) = .empty;
    try report.writeJSON(a, &absent, try report.newSummary(a, null));
    try expectContainsAll(absent.items, &.{"\"findings\": null"});

    var empty: std.ArrayList(u8) = .empty;
    const none: []report.Finding = &.{};
    try report.writeJSON(a, &empty, try report.newSummary(a, none));
    try expectContainsAll(empty.items, &.{"\"findings\": []"});
}

test "findings sort by file then line then column" {
    var findings = [_]report.Finding{
        .{ .file = "b.ts", .line = 1, .column = 1, .type = "t", .literal = "", .normalized_literal = "", .matches = &.{} },
        .{ .file = "a.ts", .line = 2, .column = 5, .type = "t", .literal = "", .normalized_literal = "", .matches = &.{} },
        .{ .file = "a.ts", .line = 2, .column = 1, .type = "t", .literal = "", .normalized_literal = "", .matches = &.{} },
        .{ .file = "a.ts", .line = 1, .column = 9, .type = "t", .literal = "", .normalized_literal = "", .matches = &.{} },
    };
    report.sortFindings(&findings);
    try testing.expectEqualStrings("a.ts", findings[0].file);
    try testing.expectEqual(@as(usize, 1), findings[0].line);
    try testing.expectEqual(@as(usize, 1), findings[1].column);
    try testing.expectEqual(@as(usize, 5), findings[2].column);
    try testing.expectEqualStrings("b.ts", findings[3].file);
}
