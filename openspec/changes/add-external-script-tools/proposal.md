## Why

User-authored tools should be able to delegate integrations such as syncing captured note context to Slack to local Python or shell scripts, without implementing those integrations inside Jort. A plain same-user subprocess would expose Jort's local data, so this extension needs an explicit authorization and OS-containment boundary rather than a general shell escape.

## What Changes

- Add an opt-in, asynchronous `jort.exec(path, payload)` capability for JavaScript tools, with JSON on stdin and bounded text stdout as the result. Paths identify locally approved scripts, not shell command strings.
- Add local Settings approval of exact tool/script/interpreter configurations, explicit network permission, revocation, and invalidation when executable content or tool configuration changes. Package declarations request authority; they never grant it.
- Introduce a separate signed, sandboxed external-script supervisor and disposable runner. Preserve the existing no-filesystem/no-network/no-process JavaScript worker sandbox and keep Jort credentials, stores, and native objects outside both script messages and script authority.
- Gate implementation on a signed macOS containment/compatibility prototype proving supported Python/shell execution can work without broad home-directory access or access to Jort state. Unsupported runtimes fail closed; no unsandboxed fallback.
- Treat external effects as nontransactional: explicit user execution, no preview/validation effects, no automatic replay or retries, and honest unknown-outcome reporting after interruption.
- Initially support approved script/runtime resources and optional outbound networking, not arbitrary user filesystem access, arbitrary command lines, models calling executables, or a bundled Python distribution.

## Capabilities

### New Capabilities

- `external-script-execution`: Approved script bindings, asynchronous JSON/text API, independent containment, bounded process lifecycle, and external-effect semantics.

### Modified Capabilities

- `deterministic-builtins`: Permit only an explicitly approved execution-phase exec message capability as an exception to the no-I/O tool surface; retain denial of ambient worker authority.
- `sandboxed-javascript-execution`: Add a versioned, narrowly scoped execution-only capability request/reply channel while retaining existing JavaScript OS authority restrictions and legacy protocol behavior.

## Impact

- Contracts and manifest versioning in `Sources/JortToolContracts`, local package/approval storage and Tools Settings in `Sources/JortSettings`, dispatch and invocation lifecycle in `Sources/JortToolRuntime`.
- QuickJS host shim, JavaScript broker/worker framing and asynchronous job pumping; new external-runner targets, entitlements, identity checks, resource enforcement, and release-signing/dependency audits.
- Existing package and model execution remain opt-out/unchanged. Approved external execution intentionally loses deterministic/pure-tool semantics and can transmit explicitly supplied content.
- Documentation, contract/runtime/native containment tests, and `./scripts/validate` coverage. No implementation or entitlement changes are included in this planning change.
