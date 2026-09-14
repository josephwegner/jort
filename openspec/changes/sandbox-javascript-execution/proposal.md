## Why

QuickJS currently parses and executes vendored C code inside Jort's main process, so a native engine defect would inherit document, credential, filesystem, network, and user-account authority even though the JavaScript-visible API is narrow. The extracted Wave 2 contracts now provide the seam needed to contain that risk before any third-party or community package flow is allowed.

## What Changes

- Replace the in-process JavaScript executor with a minimal, independently sandboxed XPC broker that launches one disposable QuickJS child for each validation or execution.
- Link QuickJS only into the disposable worker executable; the app, AppKit, Document, Settings, Contracts, ordinary Runtime client, and XPC broker no longer link or load the engine.
- Define an exact-version, allowlisted binary IPC protocol with independent source, manifest, input, output, error, metadata, and total-envelope caps enforced before application copying or decoding.
- Establish and verify hard `RLIMIT_AS`, `RLIMIT_CPU`, core/file/process/file-descriptor limits in the child before the broker sends package source, while retaining QuickJS's heap, stack, deadline, cancellation, disabled-global, module, eval, byte, and line limits.
- Give the broker its own App Sandbox with no network, arbitrary user-file, Keychain, Apple Events, device, app-group, or user-selected-file entitlement; the disposable child inherits only that sandbox.
- Make the broker own child lifecycle, wall-clock watchdog, cancellation, forced termination, output framing, and one-run disposal; cap concurrent children and reject malformed or excess work safely.
- Reduce crash, hang, timeout, cancellation, protocol/version/correlation failure, limit violation, and malformed output into bounded generation-local failures with no partial document mutation.
- Add package/link/signature/entitlement, denied-authority, resource-exhaustion, crash/hang, bounded-decoding, lifecycle-race, and engine-provenance verification.
- Keep model-provider HTTP execution in the main-process provider path and block public/community package import until containment and the later signed-release change are both verified.

## Capabilities

### New Capabilities

- `sandboxed-javascript-execution`: Defines process topology, sandbox authority, versioned bounded IPC, hard resource enforcement, disposable worker lifecycle, peer identity, and containment verification.

### Modified Capabilities

- `tool-execution-architecture`: Replaces the intermediate in-process JavaScript implementation with a broker client while preserving the executor-neutral contracts and lazy application composition boundary.
- `deterministic-builtins`: Preserves deterministic JavaScript behavior and defense-in-depth limits across the process boundary, including fail-closed authoring validation.
- `inline-command-invocation`: Maps every worker terminal outcome through the existing generation reducer and prevents failed or late workers from causing canonical mutation.
- `asynchronous-agent-runs`: Keeps model-provider networking and credentials outside the JavaScript worker while sharing only the high-level execution/lifecycle contract.

## Impact

- Adds a private XPC service target, a minimal one-run command-line worker target, separate entitlements, fixed protocol/framing code, and broker/runtime client code.
- Moves `JortJavaScript` and vendored QuickJS linkage out of the main application framework graph and into only the disposable worker.
- Changes JavaScript package validation and execution implementations behind the Wave 2 `JortToolContracts` protocols; package format and invocation behavior remain compatible.
- Adds nested-code shape, link/load-command, signature, entitlement, sandbox-denial, rlimit, watchdog, crash, malformed-frame, and race tests that the Wave 4 release manifest must later include.
- Does not implement Developer ID credential handling, notarization/stapling, Keychain migration, main-app sandboxing, or package discovery/import.
