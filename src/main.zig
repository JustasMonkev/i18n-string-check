//! i18n-string-check: a fast CI checker for hardcoded strings in TypeScript and
//! JavaScript codebases.

const std = @import("std");
const builtin = @import("builtin");

const extract = @import("extract.zig");
const fastscan = @import("fastscan.zig");
const gopath = @import("gopath.zig");
const gostd = @import("gostd.zig");
const i18nindex = @import("index.zig");
const jsonutil = @import("jsonutil.zig");
const report = @import("report.zig");
const scan = @import("scan.zig");

const exit_ok = 0;
const exit_found = 1;
const exit_usage_err = 2;

const mode_source = "source";
const mode_test = "test";

const default_config_path = ".i18n-string-check.json";

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.arena.allocator();
    const io = init.io;

    const raw_args = try init.minimal.args.toSlice(allocator);
    const args = try allocator.alloc([]const u8, raw_args.len);
    for (raw_args, args) |source, *dest| dest.* = source;

    var stdout: std.ArrayList(u8) = .empty;
    var stderr: std.ArrayList(u8) = .empty;
    const status = run(allocator, io, args[1..], &stdout, &stderr) catch |err| blk: {
        try stderr.appendSlice(allocator, @errorName(err));
        try stderr.append(allocator, '\n');
        break :blk exit_usage_err;
    };

    if (stdout.items.len > 0) try std.Io.File.stdout().writeStreamingAll(io, stdout.items);
    if (stderr.items.len > 0) try std.Io.File.stderr().writeStreamingAll(io, stderr.items);
    return status;
}

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
) !u8 {
    const cfg = parseArgs(allocator, io, args, stderr) catch |err| switch (err) {
        error.Help => return exit_ok,
        error.Reported => return exit_usage_err,
        else => return err,
    };

    const content = std.Io.Dir.cwd().readFileAlloc(io, cfg.en_json, allocator, .unlimited) catch |err| {
        try fail(allocator, stderr, "open {s}: {s}", .{ cfg.en_json, errorText(err) });
        return exit_usage_err;
    };
    var idx = i18nindex.fromBytes(allocator, content, cfg.min_length) catch |err| switch (err) {
        error.MalformedTranslations => {
            const detail = try jsonutil.describeError(allocator, content);
            try fail(allocator, stderr, "malformed en.json: {s}", .{detail});
            return exit_usage_err;
        },
        else => return err,
    };
    defer idx.deinit();

    const files = scan.discoverFiles(allocator, io, cfg.source_dir, .{
        .extensions = cfg.exts,
        .exclude = cfg.excludes,
    }) catch |err| {
        try fail(allocator, stderr, "lstat {s}: {s}", .{ cfg.source_dir, errorText(err) });
        return exit_usage_err;
    };

    var findings = scanAndMatch(allocator, io, files, cfg, idx) catch |err| switch (err) {
        error.ParseError => {
            // The failing worker recorded which file it was.
            try fail(allocator, stderr, "{s}", .{
                if (scan_error_detail.len > 0) scan_error_detail else "parse error",
            });
            return exit_usage_err;
        },
        else => return err,
    };
    if (findings) |items| {
        for (items) |*finding| finding.file = try displayPath(allocator, io, finding.file);
    }
    if (cfg.baseline.len > 0) {
        var baseline_error: []const u8 = "";
        findings = applyBaseline(allocator, io, findings, cfg.baseline, &baseline_error) catch |err| switch (err) {
            error.MalformedBaseline => {
                try fail(allocator, stderr, "malformed baseline {s}: {s}", .{ cfg.baseline, baseline_error });
                return exit_usage_err;
            },
            else => {
                try fail(allocator, stderr, "open {s}: {s}", .{ cfg.baseline, errorText(err) });
                return exit_usage_err;
            },
        };
    }
    const summary = try report.newSummary(allocator, findings);

    if (cfg.json) {
        try report.writeJSON(allocator, stdout, summary);
    } else {
        try report.writeText(allocator, stdout, summary);
    }
    return if (summary.found) exit_found else exit_ok;
}

fn fail(
    allocator: std.mem.Allocator,
    stderr: *std.ArrayList(u8),
    comptime format: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, format ++ "\n", args);
    try stderr.appendSlice(allocator, text);
}

fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied => "permission denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        else => @errorName(err),
    };
}

// -- configuration -----------------------------------------------------------

const Config = struct {
    en_json: []const u8 = "",
    source_dir: []const u8 = "",
    config_path: []const u8 = "",
    min_length: usize = 8,
    exts: []const []const u8 = &.{},
    excludes: []const []const u8 = &.{},
    json: bool = false,
    mode: []const u8 = mode_source,
    similarity_flow: bool = false,
    baseline: []const u8 = "",
    /// Why the config file failed to parse, when it did.
    config_error: []const u8 = "",
};

const default_exts = [_][]const u8{ "ts", "tsx", "js", "jsx" };

const ParseError = error{ Help, Reported } || anyerror;

fn parseArgs(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stderr: *std.ArrayList(u8),
) ParseError!Config {
    var cfg = Config{ .exts = &default_exts };
    loadConfigDefaults(allocator, io, &cfg, args) catch |err| switch (err) {
        error.MalformedConfig => {
            try fail(allocator, stderr, "malformed config {s}: {s}", .{ cfg.config_path, cfg.config_error });
            return error.Reported;
        },
        else => {
            try fail(allocator, stderr, "open {s}: {s}", .{ cfg.config_path, errorText(err) });
            return error.Reported;
        },
    };

    var excludes: std.ArrayList([]const u8) = .empty;
    try excludes.appendSlice(allocator, cfg.excludes);
    var exts_csv: []const u8 = try std.mem.join(allocator, ",", cfg.exts);
    var min_length_signed: i64 = @intCast(cfg.min_length);

    var positional: std.ArrayList([]const u8) = .empty;
    var it = FlagIterator{ .args = try reorderArgs(allocator, args) };
    while (try it.next(allocator, stderr)) |flag| {
        if (std.mem.eql(u8, flag.name, "")) {
            try positional.append(allocator, flag.value);
            continue;
        }
        if (std.mem.eql(u8, flag.name, "config")) {
            cfg.config_path = flag.value;
        } else if (std.mem.eql(u8, flag.name, "min-length")) {
            min_length_signed = std.fmt.parseInt(i64, flag.value, 10) catch {
                try failFlag(allocator, stderr, "invalid value \"{s}\" for flag -min-length: parse error", .{flag.value});
                return error.Reported;
            };
        } else if (std.mem.eql(u8, flag.name, "ext")) {
            exts_csv = flag.value;
        } else if (std.mem.eql(u8, flag.name, "mode")) {
            cfg.mode = flag.value;
        } else if (std.mem.eql(u8, flag.name, "exclude")) {
            try excludes.append(allocator, flag.value);
        } else if (std.mem.eql(u8, flag.name, "baseline")) {
            cfg.baseline = flag.value;
        } else if (std.mem.eql(u8, flag.name, "json")) {
            cfg.json = try parseBool(allocator, stderr, "json", flag.value);
        } else if (std.mem.eql(u8, flag.name, "similarity-flow")) {
            cfg.similarity_flow = try parseBool(allocator, stderr, "similarity-flow", flag.value);
        } else {
            unreachable;
        }
    }

    if (positional.items.len != 2) {
        try stderr.appendSlice(allocator, usage);
        try fail(allocator, stderr, "expected <path-to-en.json> and <source-dir>", .{});
        return error.Reported;
    }
    if (min_length_signed < 0) {
        try fail(allocator, stderr, "--min-length must be >= 0", .{});
        return error.Reported;
    }
    if (!std.mem.eql(u8, cfg.mode, mode_source) and !std.mem.eql(u8, cfg.mode, mode_test)) {
        try fail(allocator, stderr, "--mode must be \"source\" or \"test\"", .{});
        return error.Reported;
    }

    cfg.min_length = @intCast(min_length_signed);
    cfg.en_json = positional.items[0];
    cfg.source_dir = positional.items[1];
    cfg.exts = try splitCSV(allocator, exts_csv);
    cfg.excludes = excludes.items;
    return cfg;
}

fn parseBool(
    allocator: std.mem.Allocator,
    stderr: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
) !bool {
    const truthy = [_][]const u8{ "1", "t", "T", "true", "TRUE", "True" };
    const falsy = [_][]const u8{ "0", "f", "F", "false", "FALSE", "False" };
    for (truthy) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    for (falsy) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return false;
    }
    try failFlag(allocator, stderr, "invalid boolean value \"{s}\" for -{s}: parse error", .{ value, name });
    return error.Reported;
}

fn failFlag(
    allocator: std.mem.Allocator,
    stderr: *std.ArrayList(u8),
    comptime format: []const u8,
    args: anytype,
) !void {
    try fail(allocator, stderr, format, args);
    try stderr.appendSlice(allocator, usage);
    const text = try std.fmt.allocPrint(allocator, format ++ "\n", args);
    try stderr.appendSlice(allocator, text);
}

/// A parsed argument: a flag with its value, or a positional (empty name).
const Flag = struct { name: []const u8, value: []const u8 };

const known_bool_flags = [_][]const u8{ "json", "similarity-flow" };
const known_value_flags = [_][]const u8{ "config", "min-length", "ext", "mode", "exclude", "baseline" };

fn isBoolFlag(name: []const u8) bool {
    for (known_bool_flags) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn isKnownFlag(name: []const u8) bool {
    if (isBoolFlag(name)) return true;
    for (known_value_flags) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// Mirrors Go's flag package: `-name`, `--name`, `-name=value` and, for
/// non-boolean flags, `-name value`. A bare `--` or the first non-flag argument
/// ends flag parsing, and everything after it is positional.
const FlagIterator = struct {
    args: []const []const u8,
    index: usize = 0,
    flags_done: bool = false,

    fn next(self: *FlagIterator, allocator: std.mem.Allocator, stderr: *std.ArrayList(u8)) !?Flag {
        if (self.index >= self.args.len) return null;
        const s = self.args[self.index];

        if (self.flags_done or s.len < 2 or s[0] != '-') {
            self.index += 1;
            self.flags_done = true;
            return Flag{ .name = "", .value = s };
        }
        var minuses: usize = 1;
        if (s[1] == '-') {
            minuses = 2;
            if (s.len == 2) {
                self.index += 1;
                self.flags_done = true;
                return self.next(allocator, stderr);
            }
        }
        var name = s[minuses..];
        if (name.len == 0 or name[0] == '-' or name[0] == '=') {
            try fail(allocator, stderr, "bad flag syntax: {s}", .{s});
            return error.Reported;
        }
        self.index += 1;

        var value: []const u8 = "";
        var has_value = false;
        if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
            value = name[eq + 1 ..];
            has_value = true;
            name = name[0..eq];
        }
        if (!isKnownFlag(name)) {
            if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "h")) {
                try stderr.appendSlice(allocator, usage);
                return error.Help;
            }
            try failFlag(allocator, stderr, "flag provided but not defined: -{s}", .{name});
            return error.Reported;
        }
        if (isBoolFlag(name)) {
            return Flag{ .name = name, .value = if (has_value) value else "true" };
        }
        if (!has_value and self.index < self.args.len) {
            value = self.args[self.index];
            has_value = true;
            self.index += 1;
        }
        if (!has_value) {
            try failFlag(allocator, stderr, "flag needs an argument: -{s}", .{name});
            return error.Reported;
        }
        return Flag{ .name = name, .value = value };
    }
};

/// Moves flags ahead of positionals so that flags written after the two
/// required paths are still recognised.
fn reorderArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var flags: std.ArrayList([]const u8) = .empty;
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "-")) {
            try flags.append(allocator, arg);
            const trimmed = std.mem.trimStart(u8, arg, "-");
            const name = if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| trimmed[0..eq] else trimmed;
            const has_inline_value = std.mem.indexOfScalar(u8, trimmed, '=') != null;
            if (trimmed.len > 0 and isKnownFlag(name) and !has_inline_value and !isBoolFlag(name) and i + 1 < args.len) {
                i += 1;
                try flags.append(allocator, args[i]);
            }
            continue;
        }
        try positional.append(allocator, arg);
    }
    try flags.appendSlice(allocator, positional.items);
    return flags.items;
}

fn splitCSV(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    if (value.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t\n\r\x0b\x0c");
        if (part.len > 0) try out.append(allocator, part);
    }
    return out.items;
}

const ConfigError = error{MalformedConfig} || anyerror;

fn loadConfigDefaults(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *Config,
    args: []const []const u8,
) ConfigError!void {
    var path: []const u8 = undefined;
    if (configPathFromArgs(args)) |explicit| {
        path = explicit;
    } else {
        path = default_config_path;
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    }
    cfg.config_path = path;
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);

    var parsed = jsonutil.parse(allocator, content) catch {
        cfg.config_error = try jsonutil.describeError(allocator, content);
        return error.MalformedConfig;
    };
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |obj| obj,
        .null => return,
        else => return error.MalformedConfig,
    };

    if (field(object, "minLength")) |value| switch (value) {
        .integer => |n| cfg.min_length = if (n < 0) 0 else @intCast(n),
        else => return error.MalformedConfig,
    };
    if (field(object, "ext")) |value| cfg.exts = try stringArray(allocator, value);
    if (field(object, "exclude")) |value| cfg.excludes = try stringArray(allocator, value);
    if (field(object, "json")) |value| switch (value) {
        .bool => |b| cfg.json = b,
        else => return error.MalformedConfig,
    };
    if (field(object, "mode")) |value| switch (value) {
        .string => |s| if (s.len > 0) {
            cfg.mode = try allocator.dupe(u8, s);
        },
        else => return error.MalformedConfig,
    };
    if (field(object, "similarityFlow")) |value| switch (value) {
        .bool => |b| cfg.similarity_flow = b,
        else => return error.MalformedConfig,
    };
    if (field(object, "baseline")) |value| switch (value) {
        .string => |s| if (s.len > 0) {
            cfg.baseline = try allocator.dupe(u8, s);
        },
        else => return error.MalformedConfig,
    };
}

/// encoding/json matches field names case-insensitively when no exact match
/// exists, so the config accepts "minlength" as well as "minLength".
fn field(object: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    if (object.get(name)) |value| return value;
    var it = object.iterator();
    while (it.next()) |kv| {
        if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) return kv.value_ptr.*;
    }
    return null;
}

fn stringArray(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    const array = switch (value) {
        .array => |a| a,
        .null => return &.{},
        else => return error.MalformedConfig,
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        switch (item) {
            .string => |s| try out.append(allocator, try allocator.dupe(u8, s)),
            else => return error.MalformedConfig,
        }
    }
    return out.items;
}

fn configPathFromArgs(args: []const []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-config")) {
            if (i + 1 < args.len) return args[i + 1];
            return "";
        }
        if (std.mem.startsWith(u8, arg, "--config=")) return arg["--config=".len..];
        if (std.mem.startsWith(u8, arg, "-config=")) return arg["-config=".len..];
    }
    return null;
}

// -- scanning ----------------------------------------------------------------

/// Runs the per-literal match pipeline for one scan; mode and similarity_flow
/// are fixed for its lifetime. Exact and pattern lookups are cheap enough to
/// redo per occurrence, but similarity results are memoized: literals repeat
/// across a codebase and a similarity lookup walks posting lists. Cached match
/// slices are shared between findings and must not be mutated.
const MatchCache = struct {
    index: *const i18nindex.Index,
    io: std.Io,
    mode: []const u8,
    similarity_flow: bool,
    mutex: std.Io.Mutex = .init,
    /// Guarded by `mutex`. Its own storage comes from the C allocator because
    /// arenas are not thread-safe; the entries themselves are allocated from a
    /// worker arena that lives as long as the process, so readers can use them
    /// after releasing the lock.
    similar: std.StringHashMapUnmanaged([]const i18nindex.Match) = .empty,

    const Lookup = struct { matches: []const i18nindex.Match, type: []const u8 };

    /// Returns the matches for a normalized literal and the finding type they
    /// carry, mirroring the exact -> pattern -> similarity precedence.
    fn lookup(self: *MatchCache, worker: *Worker, normalized: []const u8) !Lookup {
        const exact = self.index.lookupNormalized(normalized);
        if (exact.len > 0) return .{ .matches = exact, .type = "hardcoded-translation" };
        if (!std.mem.eql(u8, self.mode, mode_source)) return .{ .matches = &.{}, .type = "" };

        const patterns = try self.index.lookupPatternNormalized(worker.persistent(), transient, normalized);
        if (patterns.len > 0) return .{ .matches = patterns, .type = "hardcoded-translation" };
        if (!self.similarity_flow) return .{ .matches = &.{}, .type = "" };

        return .{ .matches = try self.lookupSimilar(worker, normalized), .type = "changed-translation-value" };
    }

    /// The pre-scan's question: does this literal match anything at all? It
    /// mirrors `lookup`'s precedence but never builds a match list, because the
    /// answer is discarded for every candidate span that is not a real literal.
    fn hasMatch(self: *MatchCache, worker: *Worker, normalized: []const u8) !bool {
        if (self.index.lookupNormalized(normalized).len > 0) return true;
        if (!std.mem.eql(u8, self.mode, mode_source)) return false;
        if (try self.index.matchesAnyPattern(transient, normalized)) return true;
        if (!self.similarity_flow) return false;
        return (try self.lookupSimilar(worker, normalized)).len > 0;
    }

    fn lookupSimilar(self: *MatchCache, worker: *Worker, normalized: []const u8) ![]const i18nindex.Match {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.similar.get(normalized)) |cached| return cached;
        }
        // Results are memoized and shared, so they must outlive this worker's
        // current file; the worker's arena lives as long as the process.
        const allocator = worker.persistent();
        const matches = try self.index.lookupSimilarNormalized(
            allocator,
            transient,
            &worker.sim_scratch,
            normalized,
        );
        const key = try allocator.dupe(u8, normalized);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Another worker may have raced us here; either result is equivalent.
        const gop = try self.similar.getOrPut(std.heap.c_allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = matches;
        return gop.value_ptr.*;
    }
};

/// Allocator for work that is freed before the call returns. Workers run in
/// parallel and arenas are not thread-safe, so transient allocations go to
/// malloc rather than to any arena.
const transient = std.heap.c_allocator;

const Worker = struct {
    arena: std.heap.ArenaAllocator,
    session: extract.Session,
    sim_scratch: i18nindex.SimScratch,
    findings: std.ArrayList(report.Finding) = .empty,
    err: ?anyerror = null,
    /// Names the file behind `err` when it is a parse error. Written only by
    /// this worker and read only after every worker has joined.
    err_detail: []const u8 = "",

    fn persistent(self: *Worker) std.mem.Allocator {
        return self.arena.allocator();
    }
};

/// The filter handed to the extractor and the pre-scan.
const Matcher = struct {
    cache: *MatchCache,
    worker: *Worker,

    fn matchFunc(self: *Matcher) extract.MatchFunc {
        return .{ .ctx = self, .call = call };
    }

    fn call(ctx: *anyopaque, normalized: []const u8) anyerror!bool {
        const self: *Matcher = @ptrCast(@alignCast(ctx));
        return self.cache.hasMatch(self.worker, normalized);
    }
};

/// Detail for the error `scanAndMatch` returned. It is written after every
/// worker has joined, so it needs no synchronization.
var scan_error_detail: []const u8 = "";

const ScanContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    files: []const []const u8,
    cfg: Config,
    cache: *MatchCache,
    next: std.atomic.Value(usize) = .init(0),
};

fn scanAndMatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    files: []const []const u8,
    cfg: Config,
    idx: *i18nindex.Index,
) !?[]report.Finding {
    if (files.len == 0) return null;

    var languages = try extract.Languages.init(allocator);
    defer languages.deinit();

    var cache = MatchCache{
        .index = idx,
        .io = io,
        .mode = cfg.mode,
        .similarity_flow = cfg.similarity_flow,
    };
    defer cache.similar.deinit(std.heap.c_allocator);

    const cpus = std.Thread.getCpuCount() catch 1;
    const worker_count = @max(1, @min(cpus, files.len));

    const workers = try allocator.alloc(Worker, worker_count);
    for (workers) |*worker| {
        worker.* = .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .session = try extract.Session.init(),
            .sim_scratch = try i18nindex.SimScratch.init(allocator, idx),
        };
    }
    defer for (workers) |*worker| worker.session.deinit();

    var ctx = ScanContext{
        .allocator = allocator,
        .io = io,
        .files = files,
        .cfg = cfg,
        .cache = &cache,
    };

    if (worker_count == 1) {
        workerMain(&ctx, &languages, &workers[0]);
    } else {
        const threads = try allocator.alloc(std.Thread, worker_count);
        for (threads, workers) |*thread, *worker| {
            thread.* = try std.Thread.spawn(.{}, workerMain, .{ &ctx, &languages, worker });
        }
        for (threads) |thread| thread.join();
    }

    var findings: std.ArrayList(report.Finding) = .empty;
    for (workers) |*worker| {
        if (worker.err) |err| {
            scan_error_detail = worker.err_detail;
            return err;
        }
        try findings.appendSlice(allocator, worker.findings.items);
    }
    if (findings.items.len == 0) return null;
    report.sortFindings(findings.items);
    return findings.items;
}

fn workerMain(ctx: *ScanContext, languages: *const extract.Languages, worker: *Worker) void {
    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.files.len) return;
        scanOne(ctx, languages, worker, ctx.files[i]) catch |err| {
            if (worker.err == null) worker.err = err;
            return;
        };
    }
}

fn scanOne(
    ctx: *ScanContext,
    languages: *const extract.Languages,
    worker: *Worker,
    path: []const u8,
) !void {
    const content = try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, transient, .unlimited);
    defer transient.free(content);

    var matcher = Matcher{ .cache = ctx.cache, .worker = worker };
    const worth = matcher.matchFunc();

    // The pre-scan checks a cheap lexical superset of the file's literals
    // against the index. Files without a single matching candidate — the common
    // case — provably have no findings and skip parsing entirely.
    if (!try fastscan.hasCandidateMatch(transient, path, content, ctx.cfg.min_length, worth)) return;

    const allocator = worker.persistent();
    const literals = extract.bytes(
        allocator,
        languages,
        &worker.session,
        path,
        content,
        ctx.cfg.min_length,
        worth,
    ) catch |err| switch (err) {
        error.ParseError => {
            worker.err_detail = try std.fmt.allocPrint(
                worker.persistent(),
                "parse error in {s}",
                .{path},
            );
            return error.ParseError;
        },
        else => return err,
    };

    const test_mode = std.mem.eql(u8, ctx.cfg.mode, mode_test);
    for (literals) |literal| {
        const result = try ctx.cache.lookup(worker, literal.normalized_literal);
        if (result.matches.len == 0) continue;
        var finding_type = result.type;
        if (test_mode) {
            if (i18nindex.hasExactValue(result.matches, literal.literal)) continue;
            finding_type = "test-value-mismatch";
        }
        try worker.findings.append(allocator, .{
            .file = literal.file,
            .line = literal.line,
            .column = literal.column,
            .type = finding_type,
            .literal = literal.literal,
            .normalized_literal = literal.normalized_literal,
            .matches = result.matches,
        });
    }
}

// -- baseline and paths ------------------------------------------------------

const BaselineError = error{MalformedBaseline} || anyerror;

fn applyBaseline(
    allocator: std.mem.Allocator,
    io: std.Io,
    findings: ?[]report.Finding,
    path: []const u8,
    error_detail: *[]const u8,
) BaselineError!?[]report.Finding {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    var parsed = jsonutil.parse(allocator, content) catch {
        error_detail.* = try jsonutil.describeError(allocator, content);
        return error.MalformedBaseline;
    };
    defer parsed.deinit();

    var ignored: std.StringHashMapUnmanaged(void) = .empty;
    defer ignored.deinit(allocator);
    if (parsed.value == .object) {
        if (parsed.value.object.get("findings")) |value| {
            if (value == .array) {
                for (value.array.items) |item| {
                    if (item != .object) continue;
                    const signature = try baselineSignature(allocator, item.object);
                    try ignored.put(allocator, signature, {});
                }
            }
        }
    }

    const items = findings orelse return null;
    var filtered: std.ArrayList(report.Finding) = .empty;
    try filtered.ensureTotalCapacity(allocator, items.len);
    for (items) |finding| {
        const signature = try findingSignature(allocator, finding);
        defer allocator.free(signature);
        if (ignored.contains(signature)) continue;
        filtered.appendAssumeCapacity(finding);
    }
    // Go slices the original in place, so an all-suppressed run still yields an
    // empty — not nil — slice, which serializes as `[]` rather than `null`.
    return filtered.items;
}

fn baselineSignature(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    if (object.get("matches")) |matches| {
        if (matches == .array) {
            for (matches.array.items) |match| {
                if (match != .object) continue;
                if (match.object.get("key")) |key| {
                    if (key == .string) try keys.append(allocator, key.string);
                }
            }
        }
    }
    return buildSignature(
        allocator,
        jsonString(object, "file"),
        jsonString(object, "type"),
        jsonString(object, "literal"),
        keys.items,
    );
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) []const u8 {
    const value = object.get(name) orelse return "";
    return switch (value) {
        .string => |s| s,
        else => "",
    };
}

fn findingSignature(allocator: std.mem.Allocator, finding: report.Finding) ![]u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    for (finding.matches) |match| try keys.append(allocator, match.key);
    return buildSignature(allocator, finding.file, finding.type, finding.literal, keys.items);
}

fn buildSignature(
    allocator: std.mem.Allocator,
    file: []const u8,
    finding_type: []const u8,
    literal: []const u8,
    keys_in: []const []const u8,
) ![]u8 {
    const keys = try allocator.dupe([]const u8, keys_in);
    defer allocator.free(keys);
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, file);
    try out.append(allocator, 0);
    try out.appendSlice(allocator, finding_type);
    try out.append(allocator, 0);
    try out.appendSlice(allocator, literal);
    try out.append(allocator, 0);
    for (keys, 0..) |key, i| {
        if (i > 0) try out.append(allocator, 0);
        try out.appendSlice(allocator, key);
    }
    return out.toOwnedSlice(allocator);
}

/// Reports paths relative to the working directory when they sit underneath it,
/// and unchanged otherwise.
fn displayPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const cwd = std.process.currentPathAlloc(io, allocator) catch return gopath.toSlash(allocator, path);
    defer allocator.free(cwd);
    const relative = gopath.rel(allocator, cwd, path) catch return gopath.toSlash(allocator, path);
    if (std.mem.startsWith(u8, relative, "..")) {
        allocator.free(relative);
        return gopath.toSlash(allocator, path);
    }
    defer allocator.free(relative);
    return gopath.toSlash(allocator, relative);
}

const usage =
    \\i18n-string-check finds hardcoded strings that match current English translations.
    \\
    \\Usage:
    \\  i18n-string-check <path-to-en.json> <source-dir> [flags]
    \\
    \\Examples:
    \\  i18n-string-check ./locales/en.json ./src
    \\  i18n-string-check ./locales/en.json ./src --similarity-flow
    \\  i18n-string-check ./locales/en.json ./tests --mode=test
    \\  i18n-string-check ./apps/web/locales/en.json ./apps/web --min-length=8
    \\  i18n-string-check ./en.json ./tests --ext=ts,tsx
    \\
    \\Flags:
    \\  --mode=source|test
    \\      source: flag hardcoded current translation values in components/source.
    \\      test: allow direct strings, but flag case/spacing mismatches against current en.json values.
    \\      Default: source
    \\
    \\  --min-length=N
    \\      Ignore literals shorter than N chars after trimming.
    \\      Default: 8
    \\
    \\  --ext=ts,tsx,js,jsx
    \\      Comma-separated extensions to scan.
    \\      Default: ts,tsx,js,jsx
    \\
    \\  --exclude=pattern
    \\      Glob pattern to exclude.
    \\      Can be passed multiple times.
    \\
    \\  --config=path
    \\      JSON config file.
    \\      Default: .i18n-string-check.json when present in the current working directory.
    \\
    \\  --baseline=path
    \\      JSON baseline file generated from --json output.
    \\
    \\  --json
    \\      Output machine-readable JSON instead of text.
    \\
    \\  --similarity-flow
    \\      Also flag likely stale hardcoded translations using conservative similarity matching.
    \\
    \\Exit codes:
    \\  0  no hardcoded i18n strings found
    \\  1  hardcoded i18n strings found, likely stale hardcoded translations found, or test translation value mismatches found
    \\  2  IO error / parse error / bad args / malformed en.json
    \\
    \\Limitation:
    \\  Similarity matching is intentionally conservative and only applies to longer multi-word strings.
    \\
;
