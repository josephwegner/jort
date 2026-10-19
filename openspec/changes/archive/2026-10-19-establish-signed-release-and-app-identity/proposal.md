## Why

Jort's local package is intentionally unsigned and validates only part of the application, so a downloaded build has no verifiable publisher identity, sealed resource integrity, stable Keychain identity, or notarization evidence. Public distribution must become a separate, repeatable, fail-closed workflow after the Wave 3 helper topology is known, without making signing credentials a prerequisite for ordinary development.

## What Changes

- Keep the routine local build credential-free and explicitly non-distributable, and add a separate release workflow for Developer ID Application signing, distribution-image creation, notarization, stapling, Gatekeeper assessment, and final artifact verification.
- Generate one authoritative package and identity manifest from the final project target graph, then use it to validate every expected framework, XPC service, worker, resource, identifier, executable permission, entitlement, signature, and Mach-O dependency while rejecting missing, external, duplicate, or stale code.
- Sign every nested code object deliberately from the inside out with Hardened Runtime enabled, then sign the containing app and distribution image; use recursive `codesign --deep --strict` only as a final verification aid.
- Give the main app and every nested target stable production code identities and require the expected Team ID and designated requirements throughout the packaged artifact. Keep the first direct-distribution main app outside App Sandbox while preserving the Wave 3 sandbox and inheritance contract for the JavaScript broker and worker.
- Opt credential operations into the macOS Data Protection Keychain, use a production access group available only to the signed main app, and preserve nonsynchronizing `WhenUnlockedThisDeviceOnly` accessibility.
- Migrate a legacy OpenRouter item only by reading it under the intended app, writing the protected replacement, verifying the replacement, and then deleting the legacy item. Isolate development credentials in a distinct identity namespace and prove a differently signed helper and the JavaScript helpers cannot read production credentials.
- Keep signing identities, notarization authentication material, Keychain secrets, and authorization data out of source control and sanitized release logs.
- Continue blocking public/community tool-package import until both JavaScript containment and signed distribution have been implemented and verified.

## Capabilities

### New Capabilities

- `signed-release-and-app-identity`: Defines the local-versus-release build boundary, authoritative package manifest, stable code identities, inside-out Hardened Runtime signing, notarized distribution, complete artifact verification, secret handling, and the explicit main-app sandbox decision.

### Modified Capabilities

- `asynchronous-agent-runs`: Strengthens OpenRouter credential storage with the Data Protection Keychain, production/development access-group isolation, fail-safe legacy migration, and negative identity-access verification.

## Impact

- Adds a credentialed `scripts/release.sh` and generated release-manifest tooling while updating `project.yml`, entitlements, `scripts/build.sh`, packaging/image scripts, packaging tests, CI release fixtures, and release documentation.
- Validates the post-Wave-3 `JortToolContracts`, `JortToolRuntime`, private `JortJavaScriptBroker.xpc`, and disposable `JortJavaScriptWorker` graph; QuickJS must remain linked only into the worker, and an obsolete embedded `JortJavaScript.framework` must not be assumed.
- Changes the Keychain implementation in `Sources/JortSettings/ModelCredentials.swift` or its post-extraction location and adds signed identity/migration denial fixtures without exposing real production credentials.
- Requires Apple Developer ID Application and notarization credentials only for an explicit release invocation. Ordinary local builds and non-release CI remain credential-free and clearly labeled non-distributable.
- Does not add App Store distribution, silently sandbox or relocate the main app, redesign document storage, or enable public/community package import.
