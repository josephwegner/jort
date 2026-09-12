# Tool implementation verification

Local verification, updated September 10, 2026. The implementation remains in `build-jort-run-tools`; release qualification is still open. Current feedback results are maintained in `openspec/changes/build-jort-run-tools/VERIFICATION.md`.

## Implementation and authority audit

Bundled and installed definitions enter `ToolPackageRegistry` as the same `ToolPackage` type, pass the same compile-only validator, and execute through `ToolRuntime.execute` and `jort_js_run`. None of the six bundled command names select a native executor. Bundled files are immutable application resources. User edits publish immutable generations through an atomic index, and restore selects the current bundled version while retaining old user files.

The host links the QuickJS engine without its command-line tools, standard-library module, or OS bindings. It installs no module loader, network client, filesystem interface, process/shell runner, provider, native application object, plugin interface, or external-executable interface. The one callable native getter exposed to scripts reads their cancellation token. Clock and UUID arrive as captured primitive values on the frozen input object. Math.random and Date are unavailable. Host compilation occurs before `JS_DisableEval`; script eval and function-constructor paths cannot compile new source afterward. Importing another module is rejected. Each execution has a fresh runtime, bounded memory/stack, a cancellation/deadline interrupt, bounded serialization, and byte/line result validation.

Adversarial tests cover ambient authority, constructor/eval variants, imports, frozen input, duplicate promise resolution, hostile exceptions, CPU timeout, memory exhaustion, output bounds, and cancellation races. These checks establish the exposed host contract; they are not an independent security review of the vendored C engine.

The existing Settings → Tools panel now edits the same packages the editor consumes, as explicitly authorized for this change. No new Settings window architecture, marketplace/distribution interface, permission-granting system, agent, model provider, streaming output, or background-agent run was added. Package directory installation is a registry API; it does not introduce a marketplace UI.

## Evidence

- Foundation suite: 96 tests passed, including package upgrade/override preservation, invalid-package isolation, sandbox behavior, legacy settings migration, storage fault injection, history/recovery, and tool metadata comparisons.
- Native tool suite: 27 tests passed; Settings suite: 5 tests passed. The feedback introduces pending-deletion confirmation/Undo, context keyboard and handle fixes, readable errors, and new-tool save/discovery regressions.
- Real application UI: both custom-tool creation/save/discovery/execution and bundled calc completion/merge/save/relaunch passed.
- Rendered captures were inspected for wrapped and multiline source, pending source/output seams, per-invocation controls, processing, and canonical line numbers. Controls are accessibility elements and do not enter canonical text.
- Strict OpenSpec validation and whitespace checks passed during implementation.

The native suite has two established baseline visual failures: the ruler test expects a 24-point inset while the existing editor uses 12, and a footer assertion expects the old divider pixels. Both reproduced on an untouched HEAD export. The earlier unrelated wrapped-accessory regression introduced during implementation was fixed and its test passed.

## Performance observations

Debug build on this machine; these are measurements, not performance acceptance. The editor benchmark uses `CrawlLargeDocument`, with 25,000 logical lines and 1,000,000 UTF-16 units, plus the invocation line. Values below are nearest-rank p95 from local runs.

| Operation | p95 |
| --- | ---: |
| Discover six bundled packages | 2.65 ms |
| Validate calculator package | 0.49 ms |
| Start JavaScript host and calculate | 0.78 ms |
| Refresh visible connected geometry | 3.03 ms |
| Accept invocation in large document | 373.81 ms |
| Move contextual boundary across full document | 217.24 ms |
| Validate, submit, and publish | 536.70 ms |
| Dismiss result transaction | 301.26 ms |

Geometry is bounded by the laid-out viewport. Complete document transitions still incur substantial snapshot, validation, line metadata, and persistence work. Existing foundation measurements also retain the previously documented save/history performance concerns. No claim of performance qualification is made.

## Remaining release checks

Earlier runner infrastructure problems were overcome for the two real-application tool workflows. Direct `xctest` remains useful for foundation and AppKit checks; neither test path replaces a physical IME/VoiceOver journey.

Before release, qualify the baseline visual/performance failures and finish physical IME and VoiceOver checks. The OpenSpec release-gate tasks remain open for that work.
