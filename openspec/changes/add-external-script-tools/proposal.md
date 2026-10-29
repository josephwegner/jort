## Why

User-authored JavaScript tools should be able to delegate integrations, such as syncing captured note content to Slack, to trusted local scripts without implementing those integrations inside Jort. This is opt-in local automation with ordinary user permissions, not hostile-code containment; the JavaScript tool remains responsible for input selection and normal result handling.

## What Changes

- Add asynchronous `await jort.exec(path, payload)` for explicitly permitted JavaScript tools: bounded JSON stdin and bounded text stdout returned to JavaScript. Script output is inert text, never automatically interpreted as a Jort action.
- Add one local per-tool permission: “Allow this tool to execute local scripts.” Importing, saving, enabling, or restoring a package does not grant it; explicit invocation is required in addition to the toggle. There are no per-script approvals, allowlists, content/dependency hashes, edit-triggered reapprovals, or separate network permission.
- Use default `python3` resolved through a documented Homebrew/system PATH, with an optional locally configured absolute interpreter override. Launch directly with fixed arguments—no shell command strings, interpolation, shell-startup discovery, profiles, or mandatory interpreter setup. Interpreter configuration cannot come from note content. Jort does not bundle or manage Python. Python is a convenience default for `.py` files, not a language restriction: other executable files launch directly, including native binaries and executable Node or other interpreter scripts with a suitable shebang. Do not infer Node from `.js` or fall back to a shell.
- Preserve QuickJS isolation: no direct process, filesystem, or network bindings. Add bounded asynchronous host-operation plumbing through the worker/broker channel, with host-side permission, phase, invocation, and lifecycle checks. Model tools do not gain exec access.
- Give external scripts no Jort document API, native document objects, editor callbacks, or action-dispatch endpoint. The flow is captured document input → JavaScript tool → JSON stdin → script stdout as inert text → JavaScript tool result → existing Jort result handling.
- Run scripts with ordinary user permissions. Filesystem access, networking, other programs, and indirect OS automation are not isolation targets; scripts may access Jort database or app files through ordinary OS facilities. Remove the separate containment supervisors, resource grants, identity enforcement, and containment release gates from the earlier plan.
- Keep bounded input/output, concurrent stream draining, reasonable timeouts, cancellation, direct-child cleanup/reaping, and stale-result rejection. External effects are nontransactional: no automatic retry/replay or execution during validation, initialization, preview, restore, or Undo/Redo. Interruption after launch may leave an unknown external outcome; document undo does not undo external effects.

## Capabilities

### New Capabilities

- `external-script-execution`: Trusted local script execution, per-tool local permission, JSON-in/text-out API, bounded process lifecycle, and external-effect semantics without OS-containment guarantees.

### Modified Capabilities

- `deterministic-builtins`: Add an explicitly permitted execution-phase exec message capability while retaining no ambient OS authority in the JavaScript worker, existing result handling, and legacy tool/model behavior.
- `sandboxed-javascript-execution`: Add a negotiated, bounded asynchronous capability request/reply path while preserving the JavaScript sandbox and legacy protocol behavior.

## Impact

- Tool contracts and any necessary opt-in package metadata in `Sources/JortToolContracts`; local permission and optional interpreter override in Tools Settings and local storage.
- QuickJS promise/job handling, worker/broker framing, runtime dispatch, invocation ownership, and a host-side subprocess runner outside the JavaScript sandbox. Exact protocol/schema versions and launch placement remain design work.
- Existing JavaScript isolation and legacy JavaScript/model execution remain unchanged unless a JavaScript tool explicitly uses the permitted capability. No external containment architecture, runtime-resource grants, or bundled Python distribution is required.
- Focused contract, async protocol, process lifecycle, permission, and regression tests plus user documentation. This revision changes planning artifacts only; implementation and its build/test validation are separate work.
