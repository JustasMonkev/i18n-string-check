<img src="assets/logo.svg" alt="i18n-string-check logo" width="720">

# i18n-string-check

`i18n-string-check` is a fast CI checker for hardcoded strings in TypeScript and JavaScript codebases. It has two modes:

- `source`: find hardcoded UI strings whose text matches values currently present in an English translation file.
- `test`: allow direct strings in tests, but fail when a test literal differs from the current translation only by normalization, such as casing or surrounding whitespace.

It also matches nested locale JSON, interpolation placeholders, plural variants, and conservative similarity matches for likely previous versions of longer translation values after copy changes.

`en.json` is the source of truth. Code should reference translation keys through an i18n helper:

```ts
t("login.button")
```

## Why It Exists

Hardcoded translated text in components drifts when translations change. Source mode catches current translation values before they spread through source code and JSX.

Tests often intentionally use direct strings because that is what users see. Test mode supports that workflow and catches case/spacing drift when a literal still normalizes to a current translation value.

Bad in source/components:

```tsx
<Button>Sign in</Button>
```

Good:

```tsx
<Button>{t("login.button")}</Button>
expect(page.getByText("Sign in")).toBeVisible()
```

## Usage

```sh
i18n-string-check <path-to-en.json> <source-dir> [flags]
```

Install it in a JavaScript/TypeScript project and run it from npm scripts:

```sh
npm install --save-dev i18n-string-check
```

```json
{
  "scripts": {
    "i18n:string-check:source": "i18n-string-check ./locales/en.json ./src",
    "i18n:string-check:tests": "i18n-string-check ./locales/en.json ./tests --mode=test"
  }
}
```

Examples:

```sh
i18n-string-check ./locales/en.json ./src
i18n-string-check ./locales/en.json ./src --similarity-flow
i18n-string-check ./locales/en.json ./tests --mode=test
i18n-string-check ./apps/web/locales/en.json ./apps/web --min-length=8
i18n-string-check ./en.json ./tests --ext=ts,tsx
```

Flags:

```text
--mode=source|test
    source: flag hardcoded current translation values in components/source.
    test: allow direct strings, but flag case/spacing mismatches against current en.json values.
    Default: source

--min-length=N
    Ignore literals shorter than N chars after trimming.
    Default: 8

--ext=ts,tsx,js,jsx
    Comma-separated extensions to scan.
    Default: ts,tsx,js,jsx

--exclude=pattern
    Glob pattern to exclude.
    Can be passed multiple times.

--config=path
    JSON config file.
    Default: .i18n-string-check.json when present in the current working directory.

--baseline=path
    JSON baseline file generated from --json output.

--json
    Output machine-readable JSON instead of text.

--similarity-flow
    Also flag likely stale hardcoded translations using conservative similarity matching.
```

## Exit Codes

```text
0  no hardcoded i18n strings found
1  hardcoded i18n strings found, likely stale hardcoded translations found, or test translation value mismatches found
2  IO error / parse error / bad args / malformed en.json
```

Files are only parsed when a fast pre-scan finds a string that could match a
translation, so a file with syntax errors is reported (exit `2`) only if it
also contains a potential match; clean files are skipped without parsing.

## CI Usage

Run it before slower browser or E2E jobs:

```sh
npm run i18n:string-check:source
npm run i18n:string-check:tests
```

For incremental adoption, create a baseline from the current findings and then ratchet from there:

```sh
i18n-string-check ./locales/en.json ./src --json > i18n-string-check-baseline.json
i18n-string-check ./locales/en.json ./src --baseline i18n-string-check-baseline.json
```

Intentional literals can be skipped with a same-line or previous-line comment:

```ts
// i18n-string-check-ignore
const productName = "i18n-string-check";
```

Project defaults can live in `.i18n-string-check.json`:

```json
{
  "minLength": 8,
  "ext": ["ts", "tsx"],
  "exclude": ["generated"],
  "similarityFlow": true,
  "baseline": "i18n-string-check-baseline.json"
}
```

## Fixture Project

`testdata/` is a small Vite React project with Vitest unit tests, Playwright E2E tests, `package.json`, and `package-lock.json`. Its `devDependencies` include `i18n-string-check` through `file:..`, so its npm scripts resolve the CLI through `node_modules/.bin` like a real consuming project:

```sh
cd testdata
npm ci
npm run i18n:string-check:source
npm run i18n:string-check:tests
```

The Go test suite builds source snippets and temporary projects inside tests, so normal `go test ./...` does not depend on installed JavaScript fixtures.

`testdata/similarity-flow/` contains focused examples for likely stale hardcoded translation matching:

```sh
i18n-string-check ./testdata/similarity-flow/locales/en.json ./testdata/similarity-flow/src --similarity-flow
```

## Changed Translation Values

When a longer translation value changes, `--similarity-flow` can flag a hardcoded value that is similar to the current `en.json` value:

```json
{
  "login.title": "Hello my name is Justas, And I am Human, I am QA too"
}
```

If source code still contains the likely previous text:

```tsx
<h1>Hello my name is Justas, And I am Human</h1>
```

`i18n-string-check` reports a likely stale hardcoded translation with a similarity score and a short explanation:

```text
likely stale hardcoded translation: src/Login.tsx:12
  current code string:
    "Hello my name is Justas, And I am Human"

  similar en.json value:
    key: "login.title"
    value: "Hello my name is Justas, And I am Human, I am QA too"

  similarity: 82%
  why: source string is contained in the current translation value; 82% word overlap
  fix: replace with t("login.title"), or mark this literal intentional
```

Exact hardcoded current values are still reported as `hardcoded translation`.

## Nested, Interpolation, And Plurals

Nested locale files are flattened to dot keys:

```json
{
  "login": {
    "button": "Sign in"
  }
}
```

The key above is reported as `login.button`.

Interpolation and plural values are treated as translation patterns, so source strings like `"Hello, Bob"`, `"2 items"`, or `"3 invites"` can match values such as:

```json
{
  "profile.greeting": "Hello, {name}",
  "cart.item_other": "{count} items",
  "invite": "{count, plural, one {# invite} other {# invites}}"
}
```
