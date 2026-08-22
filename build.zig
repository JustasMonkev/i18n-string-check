const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tree_sitter = treeSitterRuntime(b, target, optimize);
    const grammars = [_]*std.Build.Step.Compile{
        grammar(b, target, optimize, .{
            .name = "tree-sitter-javascript",
            .root = "vendor/tree-sitter-javascript/src",
            .files = &.{ "parser.c", "scanner.c" },
        }),
        grammar(b, target, optimize, .{
            .name = "tree-sitter-typescript",
            .root = "vendor/tree-sitter-typescript/typescript/src",
            .files = &.{ "parser.c", "scanner.c" },
        }),
        grammar(b, target, optimize, .{
            .name = "tree-sitter-tsx",
            .root = "vendor/tree-sitter-typescript/tsx/src",
            .files = &.{ "parser.c", "scanner.c" },
        }),
    };

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.link_libc = true;
    exe_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    exe_mod.linkLibrary(tree_sitter);
    for (grammars) |g| exe_mod.linkLibrary(g);

    const exe = b.addExecutable(.{
        .name = "i18n-string-check",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run i18n-string-check").dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.link_libc = true;
    test_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    test_mod.linkLibrary(tree_sitter);
    for (grammars) |g| test_mod.linkLibrary(g);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run the test suite").dependOn(&run_unit_tests.step);
}

const c_flags = [_][]const u8{
    "-std=c11",
    // Upstream tree-sitter and the generated grammars are warning-clean under
    // their own build, but not under Zig's stricter defaults; the vendored
    // sources are unmodified, so silence the noise rather than patch them.
    "-Wno-unused-but-set-variable",
    "-Wno-unused-parameter",
    "-Wno-unused-value",
    // The grammars at these revisions declare their external-scanner hooks with
    // an empty parameter list — `create()` rather than `create(void)` — while
    // the runtime calls them through a `void *(*)(void)` pointer. That is a
    // function-pointer type mismatch, and undefined behaviour by the letter of
    // the standard even though no arguments are passed either way. It is the
    // one check ReleaseSafe traps on here, so it is disabled for the vendored
    // sources; every other sanitizer check stays on. Upstream fixed the
    // declarations after these revisions, so this can go when the grammars are
    // next updated.
    "-fno-sanitize=function",
};

fn treeSitterRuntime(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize });
    mod.link_libc = true;
    mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    mod.addCSourceFiles(.{
        .root = b.path("vendor/tree-sitter/src"),
        // lib.c is upstream's amalgamation of exactly these files; the
        // translation units are compiled separately instead.
        .files = &.{
            "alloc.c",
            "get_changed_ranges.c",
            "language.c",
            "lexer.c",
            "node.c",
            "parser.c",
            "query.c",
            "stack.c",
            "subtree.c",
            "tree.c",
            "tree_cursor.c",
            "wasm_store.c",
        },
        .flags = &c_flags,
    });
    return b.addLibrary(.{
        .name = "tree-sitter",
        .root_module = mod,
        .linkage = .static,
    });
}

const Grammar = struct {
    name: []const u8,
    root: []const u8,
    files: []const []const u8,
};

fn grammar(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    spec: Grammar,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize });
    mod.link_libc = true;
    // Generated grammars include "tree_sitter/parser.h" from their own tree.
    mod.addIncludePath(b.path(spec.root));
    mod.addCSourceFiles(.{
        .root = b.path(spec.root),
        .files = spec.files,
        .flags = &c_flags,
    });
    return b.addLibrary(.{
        .name = spec.name,
        .root_module = mod,
        .linkage = .static,
    });
}
