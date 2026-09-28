# QuickJS security review checklist

Complete this checklist before every Jort release and at least every 90 days from
the review date in `Vendor/QuickJS/JORT.md`.

## Upstream and vulnerability review

- Confirm the upstream archive URL, version, and SHA-256 against the vendoring record.
- Review upstream releases and changelog entries since the pinned version.
- Search upstream issue/advisory sources and public vulnerability databases for QuickJS reports.
- Decide explicitly whether each relevant fix requires an update or is unreachable in Jort's reduced build.
- Confirm the imported-file inventory still excludes the CLI, standard library, module loader, and OS bindings.

## Local patch and containment review

- Regenerate and compare `Vendor/QuickJS/JORT.patch`; investigate every changed line.
- Confirm QuickJS and the native shim link only into `JortJavaScriptWorker`.
- Confirm the broker and worker identifiers, nested locations, signatures, and entitlements.
- Confirm the worker receives no path, bookmark, credential, provider, document, or callback capability.
- Confirm public/community package import remains disabled until the containment and signed-release changes are verified.
- Record that macOS manages whole-process memory pressure; Jort intentionally provides no process-memory ceiling or memory watchdog.

## Toolchain and analyzer review

- Run the first-party and QuickJS analyzer lanes through `./scripts/validate gate`.
- Compare the current compiler, SDK, flags, source hashes, and diagnostics with `docs/quickjs-analyzer-provenance.json`.
- Inspect the complete QuickJS analyzer report and `baseline-diff.json`.
- Investigate every added and removed diagnostic; removal can indicate lost analyzer coverage.
- Never accept a dependency, compiler, patch, diagnostic, or baseline change by mechanically replacing the baseline.
- Update provenance or baseline only after recording the reviewer, date, rationale, and evidence.

## Approval record

Record the review date, reviewer, pinned version, toolchain, diagnostic delta,
vulnerability findings, local-patch decision, and whether a dependency/baseline
update was approved. A failed or incomplete item blocks release qualification.

### Interim review — 2026-09-25

- Reviewer: Codex implementation audit. The user approved the analyzer
  baseline/provenance refresh in this task on 2026-09-25.
- Pin: QuickJS 2026-06-04. The upstream release page still lists this archive.
- Toolchain delta: Xcode 16.4 / Apple clang 17 to Xcode 26.6 / Apple clang 21.
  The analyzer reports two added and two removed diagnostics in unchanged
  vendored C. One `quickjs.c:1722` change is wording at the same site; the new
  `quickjs.c:1616` finding concerns arena free-list state. The source initializes
  that state in `js_malloc_new_arena`; this does not by itself prove a new
  runtime defect. The removed `libregexp.c:308` report may reflect changed
  analyzer coverage and is not silently discarded.
- Public upstream reports reviewed: [BigInt interrupt-bypass and five other
  findings](https://github.com/bellard/quickjs/issues/545), [crafted-bytecode
  heap overflow](https://github.com/bellard/quickjs/issues/499), and [Resizable
  ArrayBuffer/Atomics use-after-free](https://github.com/bellard/quickjs/issues/508).
  Jort installs an interrupt handler and an independent OS CPU limit; it accepts
  source text, not externally supplied bytecode; and its reduced intrinsic set
  does not install Atomics/TypedArrays. These are reachability assessments, not
  proof that vendored QuickJS is free of native defects. The worker sandbox and
  disposable process remain mandatory.
- Local patch decision: no new QuickJS source patch in this review. The two
  existing host hooks remain the complete local diff. Public/community package
  import remains disabled.
- Status: analyzer baseline/provenance updated for this toolchain after reviewing
  each diagnostic delta. This is not approval of an engine update or evidence of
  zero native defects. Full release qualification still awaits the remaining
  containment fixtures.
