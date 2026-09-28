# Jort QuickJS vendoring record

- Upstream release: QuickJS 2026-06-04
- Archive: https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz
- Archive SHA-256: `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`
- License: upstream MIT; preserved verbatim in `LICENSE`
- Last security review: 2026-09-22
- Next scheduled review: no later than 2026-12-21 and before every Jort release

## Imported inventory

Only the interpreter and its direct dependencies are imported: `quickjs.c`,
`quickjs.h`, `quickjs-atom.h`, `quickjs-opcode.h`, `cutils.c`, `cutils.h`,
`dtoa.c`, `dtoa.h`, `libregexp.c`, `libregexp.h`, `libregexp-opcode.h`,
`libunicode.c`, `libunicode.h`, `libunicode-table.h`, and `list.h`. The upstream
CLI, compiler, standard-library module, tests, build system, filesystem bindings,
and operating-system bindings are deliberately omitted.

## Reproducible verification and import

Run from the repository root:

```sh
curl -L --fail https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz \
  -o /tmp/quickjs-2026-06-04.tar.xz
echo 'b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a  /tmp/quickjs-2026-06-04.tar.xz' \
  | shasum -a 256 -c -
mkdir -p /tmp/jort-quickjs-upstream
tar -xJf /tmp/quickjs-2026-06-04.tar.xz -C /tmp/jort-quickjs-upstream
```

Copy only the imported inventory above, preserve `LICENSE`, then apply
`Vendor/QuickJS/JORT.patch`. Run `./scripts/validate focused foundation` while
iterating and `./scripts/validate gate` after the final code change.

## Local patch

`Vendor/QuickJS/JORT.patch` is the complete diff from the verified upstream
`quickjs.c` and `quickjs.h`. It adds exactly two host hooks:

- `JS_DisableEval` clears the context's evaluation hook after the host compiles
  the entry module. This blocks direct/indirect eval and constructor paths
  (`Function`, `AsyncFunction`, and `GeneratorFunction`) without source filtering.
- `JS_IsToolModule` inspects compiled module metadata without evaluating it,
  requires a default export, and rejects static imports.

No other vendored source differs from the verified archive.

## Analyzer and review policy

The blocking QuickJS analyzer lane records its exact toolchain, flags, source
hashes, diagnostics, and baseline delta. A changed dependency, local patch,
compiler, analyzer diagnostic, or baseline is never accepted by refreshing the
receipt alone. Follow `docs/quickjs-security-review.md`, inspect the complete
retained report, and record explicit approval before updating either provenance
or baseline.
