---
name: jort-development
description: Implement, debug, test, or review Jort with its compact validation and model-routing workflow.
---

# Jort development

Use `./scripts/validate` as the only routine build and test entry point.

1. Inspect the request and changed files. Use `./scripts/validate changed --plan-only` when the working tree is relevant.
2. During implementation, run `focused foundation` or `focused native`, with repeated `--only` XCTest IDs when known. Use `--configuration Release` or `--performance` only when needed.
3. On failure, read the bounded terminal excerpt and `summary.json`. Use `./scripts/validate result --check NAME` for at most 80 trailing lines. Open a full log only when the excerpt cannot identify the failure.
4. After the final code edit, run `./scripts/validate gate` once. A later code edit requires fresh relevant validation. Prior passing summaries are diagnostic records, never a test cache.

Delegate bounded independent work: `explorer` for code discovery, `test-triage` for a stored failure log, `implementer` for routine isolated changes, `hard-problem` for ambiguous cross-module correctness, and `reviewer` for final review. The coordinator owns integration and validation selection.

All Xcode-backed checks share a lock. Wait for the dispatcher instead of launching another Xcode process. Complete logs live under `.build-validation`; chat output should contain statuses, timings, paths, and bounded diagnostics.
