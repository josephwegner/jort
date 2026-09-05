# Review handoff implementation status

This document supersedes the original prototype implementation notes where they conflict. The handoff's product decisions are retained: any save-stage failure is a failed save, prominent error recovery remains, the app is dark-only, emoji remains the primary landmark language, timestamps remain data, and recovery import/unsafe-load UX are deferred.

## Implemented foundations

| Review item | Implementation |
|---|---|
| One document owner | `DocumentCoordinator` is the only mutable live DocumentState. Typed transactions validate before committing; observers project results into AppKit and persistence. |
| Migration | Explicit v1 decoder and v2 envelope/payload DTO, with renamed fields and additive defaults. Transactional staged SQLite v2 creation; originals preserved. |
| Atomic recovery | Exclusive lock, sibling replacement, close/reopen validation, and an atomic directory swap. Database and WAL companions never separate during installation. |
| Single process | Process-lifetime `flock` on the selected data root; duplicate ownership refuses all load/recovery/write operations. OS releases locks on crash. |
| Revisions | Coordinator assigns exactly one revision per accepted transaction. Successful persistence returns a committed revision; history IDs remain a separate future concern. |
| Line identity | Approved textual-lineage rules documented normatively. Detached references never match nearby text or duplicate emoji. Domain landmark prototypes cover deletion, split/join, emoji changes, and duplicates. |
| Modules | Four compiler-enforced targets: Document, Persistence, AppKit, application. Separate headless and native test schemes. |
| Concurrency | Swift 6 complete strict concurrency. SQLite connection belongs to its storage actor; scheduler/UI callbacks are MainActor; snapshots are Sendable. |
| Typed status | Loading, clean, dirty, writing, retry scheduled, failed/exhausted, future refusal, load failure, and ownership contention. Copy stays in the AppKit layer. |
| Performance | Committed 10k-line fixture and percentile reports; CI regression ceilings, native sustained-edit/gutter/save/deep-undo workflow, and bounded undo depth. |
| Configuration | project.yml and pinned generator; explicit application plist with build-setting version substitutions, deterministic regeneration check, and CI workflow. |
| Packaging | Fresh validated staging bundle and atomic replacement; stale files cannot survive. Local-only unsigned output is explicit. |
| SQLite safety | Checked bind/size/configuration operations, exact schema/column validation, protected future/unknown versions, and preserved primary errors with secondary rollback diagnostics. |

## Verification performed

- 19 headless tests passed, including real two-process races, crash/WAL reopening, all released migrations, injected recovery/migration failures, future/unknown refusal, typed save retries, concurrent flush waiters, actual SQLite busy errors, read-only snapshot failure, and oversize saves.
- Those 19 headless tests passed under Thread Sanitizer with no reported races.
- The AppKit framework builds with Swift 6 strict concurrency and passes static analysis.
- Native adapter tests passed earlier in the refactor; they are being rechecked in an unhosted command-line test bundle after the user's restriction on modifying app/test-runner bundles.
- Deterministic generation and fresh packaging/failure preservation checks pass.
- Full accessibility smoke testing was not completed: macOS rejected the original unsigned generated UI runner. The user canceled it and declined further runner modification. A separate user-run `scripts/test-ui.sh` now creates an ad-hoc-signed test build; security protections are not bypassed.
- The final application/Release artifact has not been rebuilt or replaced after that restriction. Run `scripts/build.sh` yourself when ready. Existing installed applications and user data have not been migrated during the source refactor.

## Explicit remaining validation limits

Remote CI cannot be claimed as executed because this workspace has no Git repository/remote. Physical IME input sources, VoiceOver's complete user journey, power-loss durability, and memory distributions across real hardware still need release qualification. History checkpoints and public distribution signing/notarization remain future phases, not incomplete Crawl features. The new UI smoke test still needs the user-run validation above before treating the full end-user lifecycle gate as passed.
