//! Source-file discovery.

const std = @import("std");
const gopath = @import("gopath.zig");

pub const default_excluded = [_][]const u8{
    "node_modules",
    ".git",
    "dist",
    "build",
    "coverage",
    ".next",
    "playwright-report",
    "test-results",
};

pub const Options = struct {
    extensions: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
};

/// Where a walk failed, so the message can name the path Go's would have.
pub const Failure = struct {
    /// The syscall Go's error would name.
    op: []const u8 = "lstat",
    /// Owned by the allocator passed to discoverFiles.
    path: []const u8 = "",
};

const default_extensions = [_][]const u8{ "ts", "tsx", "js", "jsx" };

pub fn discoverFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    opts: Options,
    failure: *Failure,
) ![][]const u8 {
    var extensions: std.StringHashMapUnmanaged(void) = .empty;
    defer extensions.deinit(allocator);
    try normalizeExtensions(allocator, opts.extensions, &extensions);

    var excludes: std.ArrayList(ExcludePattern) = .empty;
    defer excludes.deinit(allocator);
    try compileExcludes(allocator, &default_excluded, &excludes);
    try compileExcludes(allocator, opts.exclude, &excludes);

    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(allocator);

    var walker = Walker{
        .allocator = allocator,
        .io = io,
        .root = root,
        .failure = failure,
        .extensions = &extensions,
        .excludes = excludes.items,
        .files = &files,
    };
    try walker.walk();

    const result = try files.toOwnedSlice(allocator);
    std.mem.sort([]const u8, result, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return result;
}

fn normalizeExtensions(
    allocator: std.mem.Allocator,
    exts: []const []const u8,
    out: *std.StringHashMapUnmanaged(void),
) !void {
    const source = if (exts.len == 0) &default_extensions else exts;
    for (source) |raw| {
        var cleaned = raw;
        if (std.mem.startsWith(u8, cleaned, ".")) cleaned = cleaned[1..];
        cleaned = std.mem.trim(u8, cleaned, " \t\n\r\x0b\x0c");
        if (cleaned.len == 0) continue;
        try out.put(allocator, cleaned, {});
    }
}

const ExcludePattern = struct {
    pattern: []const u8,
    is_glob: bool,
};

/// Cleans the patterns once so the per-entry match loop does not re-trim and
/// re-classify each pattern for every walked path.
fn compileExcludes(
    allocator: std.mem.Allocator,
    patterns: []const []const u8,
    out: *std.ArrayList(ExcludePattern),
) !void {
    for (patterns) |raw| {
        const pattern = std.mem.trim(u8, raw, " \t\n\r\x0b\x0c");
        if (pattern.len == 0) continue;
        const slash_pattern = try gopath.toSlash(allocator, pattern);
        try out.append(allocator, .{
            .pattern = slash_pattern,
            .is_glob = std.mem.indexOfAny(u8, slash_pattern, "*?[") != null,
        });
    }
}

const Walker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    failure: *Failure,
    extensions: *const std.StringHashMapUnmanaged(void),
    excludes: []const ExcludePattern,
    files: *std.ArrayList([]const u8),

    fn walk(self: *Walker) !void {
        // A missing root is an error, as it is for Go's WalkDir; a root that is
        // a regular file simply yields nothing, also as it does there.
        self.failure.* = .{ .op = "lstat", .path = self.root };
        // WalkDir stats the root without following it, then stops unless it is
        // a directory. A symlinked root is therefore visited but never
        // descended into, which also keeps this walk's rule that a link cannot
        // pull files in from outside the tree.
        const info = try std.Io.Dir.cwd().statFile(self.io, self.root, .{ .follow_symlinks = false });
        if (info.kind != .directory) return;

        self.failure.* = .{ .op = "open", .path = self.root };
        const dir = try std.Io.Dir.cwd().openDir(self.io, self.root, .{ .iterate = true });
        defer dir.close(self.io);
        try self.walkDir(dir, self.root);
    }

    fn walkDir(self: *Walker, dir: std.Io.Dir, dir_path: []const u8) !void {
        // Entries are visited in lexical order so that an exclusion applied to
        // a directory deterministically prunes everything beneath it; the final
        // list is sorted regardless.
        var names: std.ArrayList(Entry) = .empty;
        defer {
            for (names.items) |entry| self.allocator.free(entry.name);
            names.deinit(self.allocator);
        }
        self.failure.* = .{ .op = "open", .path = dir_path };
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            try names.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, entry.name),
                .kind = entry.kind,
            });
        }
        std.mem.sort(Entry, names.items, {}, Entry.lessThan);

        for (names.items) |entry| {
            const path = try gopath.join(self.allocator, &.{ dir_path, entry.name });
            var keep_path = false;
            defer if (!keep_path) self.allocator.free(path);

            const rel = gopath.rel(self.allocator, self.root, path) catch continue;
            defer self.allocator.free(rel);
            if (std.mem.eql(u8, rel, ".")) continue;

            if (try self.matchesExclude(rel, entry.name)) continue;

            // Some filesystems (NFS and several FUSE drivers) report entries
            // without a kind. Go's ReadDir resolves those with an lstat before
            // handing them over, so do the same rather than skipping them and
            // silently reporting a clean scan.
            const kind = if (entry.kind == .unknown)
                (dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => continue, // vanished mid-walk
                    else => {
                        self.failure.* = .{ .op = "lstat", .path = path };
                        keep_path = true; // the message outlives this iteration
                        return err;
                    },
                }).kind
            else
                entry.kind;

            // Symlinks are never followed and never scanned, so a link cannot
            // pull a file from outside the tree into the report.
            if (kind == .sym_link) continue;

            if (kind == .directory) {
                // An unreadable subdirectory is an error, not an empty one:
                // silently skipping it would hide every file underneath and
                // still exit 0. Go's WalkDir propagates the same failure.
                const child = dir.openDir(self.io, entry.name, .{ .iterate = true }) catch |err| {
                    self.failure.* = .{ .op = "open", .path = path };
                    keep_path = true; // the message outlives this iteration
                    return err;
                };
                defer child.close(self.io);
                try self.walkDir(child, path);
                self.failure.* = .{ .op = "open", .path = dir_path };
                continue;
            }
            if (kind != .file) continue;

            var extension = gopath.ext(path);
            if (std.mem.startsWith(u8, extension, ".")) extension = extension[1..];
            if (self.extensions.contains(extension)) {
                try self.files.append(self.allocator, path);
                keep_path = true;
            }
        }
    }

    fn matchesExclude(self: *Walker, rel: []const u8, base: []const u8) !bool {
        const slash_rel = try gopath.toSlash(self.allocator, rel);
        defer self.allocator.free(slash_rel);
        for (self.excludes) |exclude| {
            if (!exclude.is_glob) {
                if (std.mem.eql(u8, base, exclude.pattern) or
                    std.mem.eql(u8, slash_rel, exclude.pattern) or
                    hasPathSegment(slash_rel, exclude.pattern)) return true;
                continue;
            }
            if (gopath.match(exclude.pattern, slash_rel)) return true;
            if (gopath.match(exclude.pattern, base)) return true;
        }
        return false;
    }
};

const Entry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

fn hasPathSegment(path: []const u8, segment: []const u8) bool {
    var start: usize = 0;
    while (start <= path.len) {
        const end = std.mem.indexOfScalar(u8, path[start..], '/') orelse {
            return std.mem.eql(u8, path[start..], segment);
        };
        if (std.mem.eql(u8, path[start .. start + end], segment)) return true;
        start += end + 1;
    }
    return false;
}
