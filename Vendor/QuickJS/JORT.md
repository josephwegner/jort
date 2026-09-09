QuickJS 2026-06-04, https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz
Archive SHA-256: b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a

Only the interpreter and its dependencies are built. No quickjs-libc, CLI,
module loader, filesystem, or operating-system bindings are included.
See LICENSE for the upstream MIT license.

Local extension: JS_DisableEval clears the context's evaluation hook after the
host compiles the entry module. This also blocks indirect eval and constructor
paths (Function, AsyncFunction, GeneratorFunction), without source filtering.
JS_IsToolModule inspects compiled module metadata without evaluating it, requiring
a default export and rejecting static imports.
