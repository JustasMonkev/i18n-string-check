# Unicode table generator

`src/unicode_tables.zig` is generated, committed source. It holds the code point
ranges behind `unicode.IsSpace`, `IsLetter`, `IsDigit` and `IsPrint`, plus the
`unicode.ToLower` mapping.

The checker's normalization, tokenization and quoting are all specified in terms
of those predicates, and Zig's standard library does not carry the same tables.
Rather than approximate them, `main.go` walks every code point and asks Go
directly, so the emitted ranges agree with Go's tables by construction.

Nothing in the normal build runs this. It is only needed to refresh the tables
against a newer Unicode revision, which is why it is the one Go file left in the
repository:

```sh
go run ./tools/gen_unicode src/unicode_tables.zig
zig fmt src/unicode_tables.zig
```
