# Vendored C dependencies

`i18n-string-check` parses TypeScript and JavaScript with [tree-sitter], whose
runtime and grammars are C. They are vendored here so the build is hermetic:
`zig build` needs no network access and no system tree-sitter installation.

The sources are unmodified upstream files, pinned to the exact revisions listed
below. Only the files needed to build the parser are kept (parser tables,
scanners, headers and licenses); tests, bindings for other languages, and
grammar definition sources are omitted.

| Directory                  | Upstream                                          | Version  | Revision                                   |
| -------------------------- | ------------------------------------------------- | -------- | ------------------------------------------ |
| `tree-sitter/`             | https://github.com/tree-sitter/tree-sitter            | v0.22.6  | `b40f342067a89cd6331bf4c27407588320f3c263` |
| `tree-sitter-javascript/`  | https://github.com/tree-sitter/tree-sitter-javascript | v0.21.4  | `d767b1a276a4e80d7a6be30bada3070740ba4fa2` |
| `tree-sitter-typescript/`  | https://github.com/tree-sitter/tree-sitter-typescript | v0.21.2  | `9f804be960f289a0acc59d8564acc16857b0b088` |

The grammar revisions are the same ones the previous Go implementation used
through `github.com/smacker/go-tree-sitter`, so the ported checker parses
sources exactly as it did before.

Each vendored project keeps its own `LICENSE` file; all three are MIT.

## Known quirk at these revisions

All three grammars declare their external-scanner hooks with an empty parameter
list (`void *tree_sitter_x_external_scanner_create()`), while the runtime calls
them through a `void *(*)(void)` pointer. That is a function-pointer type
mismatch — undefined behaviour by the letter of C, though no arguments are
passed either way and every ABI in use handles it. Zig's `ReleaseSafe` traps on
it, so `build.zig` compiles the vendored sources with `-fno-sanitize=function`;
every other sanitizer check stays enabled. Upstream corrected the declarations
after these revisions, so the flag can be dropped when the grammars are updated.

[tree-sitter]: https://tree-sitter.github.io/tree-sitter/
