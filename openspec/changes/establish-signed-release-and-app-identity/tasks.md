## 1. Freeze the post-Wave-3 release boundary

- [ ] 1.1 Confirm the implemented Wave 2/3 generated target graph, nested bundle paths, and module dependencies, and record the exact shipping code/resource inventory without carrying forward obsolete framework assumptions.
- [ ] 1.2 Assign and test the stable `dev.jort.editor`, `dev.jort.editor.javascript-broker`, and `dev.jort.editor.javascript-worker` identities and reconcile the broker caller/worker peer requirements with the production Team-ID placeholder.
- [ ] 1.3 Add a committed versioned release-role policy covering the app, every framework, XPC broker, disposable worker, allowed system dependency roots, required resources, entitlement allow/deny sets, and the worker-only QuickJS role.
- [ ] 1.4 Define the generated package/identity manifest schema, including containment, paths, identifiers, modes, architectures, versions, entitlements, Team relationships, dependencies, resources, forbidden roles, hashes, source revision, and toolchain metadata.
- [ ] 1.5 Add representative complete, missing-target, duplicate-path/identifier, stale-engine-framework, malformed-resource, and unexpected-executable graph fixtures for manifest and package tests.

## 2. Generate one authoritative package manifest

- [ ] 2.1 Implement graph extraction from `project.yml` and the generated Xcode project with deterministic target/dependency/resource ordering and explicit failure for unsupported declarations.
- [ ] 2.2 Resolve the selected Release build settings and Info.plist outputs for product paths, executable names, bundle identifiers, versions, architectures, runpaths, and signing/entitlement inputs.
- [ ] 2.3 Merge only the committed security-role policy facts that cannot be inferred from the project graph and reject missing roles, duplicate claims, unresolved targets, destination collisions, and policy/graph drift.
- [ ] 2.4 Inventory declared application resources, bundled tool folders, icon, and nested code destinations from source declarations rather than accepting the built bundle as its own expectation.
- [ ] 2.5 Emit a deterministic immutable manifest with schema/toolchain/project/source hashes and add a validator that rejects unknown schema versions, unsafe paths, links escaping the bundle, and inconsistent containment.
- [ ] 2.6 Integrate manifest generation into deterministic project generation, local packaging, release packaging, and package tests so none retains an independent framework/resource list.
- [ ] 2.7 Add tests proving the final broker/worker graph is required, QuickJS has exactly one worker role, and adding or removing any shipping target forces an explicit manifest-policy update.

## 3. Make packaging validation complete and phase-aware

- [ ] 3.1 Refactor `scripts/package.py` around a unique run-owned staging directory and exact manifest paths while preserving the last valid local artifact on validation or swap failure.
- [ ] 3.2 Validate every declared Info.plist identity/version, executable path and mode, architecture, icon, bundled tool file, ordinary resource, nested-code path, and containment relationship.
- [ ] 3.3 Reject undeclared executable or Mach-O content, stale code roles, duplicate identities, unexpected special files, unsafe symbolic links, missing resources, and bytes outside the manifest's allowed tree.
- [ ] 3.4 Implement per-object Mach-O load-command and `LC_RPATH` inspection with correct `@rpath`, `@loader_path`, and `@executable_path` resolution and an explicit platform-system dependency allowlist.
- [ ] 3.5 Implement load-command, symbol, and packaged-runtime checks proving QuickJS/JortJavaScript occurs only in `JortJavaScriptWorker` and that the app, frameworks, and broker remain engine-free.
- [ ] 3.6 Record a pre-sign resource/layout inventory and make post-app-sign and mounted-DMG phases prove no relevant code, resource, plist, permission, path, or signing-sensitive attribute changed unexpectedly.
- [ ] 3.7 Expand packaging fixtures to fail independently for each missing framework/helper/resource, broken executable mode, stale file, external or unresolved dependency, bad runpath, wrong architecture, and forbidden QuickJS linkage.
- [ ] 3.8 Keep `scripts/build.sh` credential-free, use the common manifest validator, support the signed-helper development mode required by Wave 3, and label its result local-only without a public release name.

## 4. Configure identities, entitlements, and inside-out signing

- [ ] 4.1 Replace the global signing prohibition with explicit Development/local and Release settings, enabling Hardened Runtime for all shipping Release code without requiring Developer ID credentials during routine builds.
- [ ] 4.2 Add target-specific main-app, broker, and worker entitlement files and tests: main app has only the production credential group and no App Sandbox; broker has the independent minimal sandbox; worker has exactly sandbox plus inherit and no prohibited authority or runtime exception.
- [ ] 4.3 Ensure frameworks carry no authority-bearing entitlements and every shipping target's generated identifier, executable, nested location, and Release settings match the manifest policy.
- [ ] 4.4 Implement a containment-depth signing planner that enumerates every manifest code object exactly once from leaves through worker, XPC, remaining nested code, and outer app without recursive deep signing.
- [ ] 4.5 Sign each planned object with the exact Developer ID Application identity, secure timestamp, Hardened Runtime option, and only its role-specific entitlements, then prohibit content mutation after containing signatures are applied.
- [ ] 4.6 Implement immediate per-object verification of identifier, Team ID, designated requirement, certificate fingerprint/validity, secure timestamp, Hardened Runtime, entitlements, and peer-requirement consistency.
- [ ] 4.7 Add final `codesign --verify --deep --strict --verbose=4` as a verification-only closure gate and negative fixtures for ad-hoc, wrong-Team, wrong-identifier, missing-runtime, broad-entitlement, and invalid-resource signatures.
- [ ] 4.8 Build and run signed Apple Development fixtures that exercise the actual nested helper identities and entitlements without using production certificates or weakening release assertions.

## 5. Move model credentials to identity-scoped Data Protection Keychain storage

- [ ] 5.1 Define immutable production and development credential policies with their exact disjoint service, account, access-group suffix, accessibility, and synchronization values, selected explicitly by build/composition configuration.
- [ ] 5.2 Centralize Security query construction so add, read, update, delete, migration verification, and cleanup all include `kSecUseDataProtectionKeychain: true`, `kSecAttrSynchronizable: false`, and the exact selected namespace.
- [ ] 5.3 Apply `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and the selected access group on every protected create/replace, verify the release Team-ID prefix, and fail closed rather than retrying a legacy or broader query.
- [ ] 5.4 Implement a single-flight credential migration state machine serialized with connect, replace, disconnect, status check, and runtime reads so no consumer observes a partial or unverified migration.
- [ ] 5.5 Implement production-only legacy read, bounded credential validation, protected write, exact protected read-back comparison, legacy delete, and final protected/legacy verification in copy-verify-delete order.
- [ ] 5.6 Implement typed nonsecret outcomes for pre-verification failure, matching-copy cleanup failure/retry, protected-versus-legacy conflict, unavailable entitlement/identity, and rollback reconnection guidance without automatic downgrade copies.
- [ ] 5.7 Wire Runtime and Models Settings to the selected protected credential interface while keeping credential bytes out of settings metadata, provider diagnostics, documents, history, recovery, package storage, and logs.
- [ ] 5.8 Add exhaustive Security-adapter tests for complete query dictionaries, every migration failure boundary, concurrent operations, conflicts, cleanup retries, development isolation, and preservation of the prior working credential.
- [ ] 5.9 Add signed disposable canary targets proving the authorized main-app host can use its test group while a differently identified helper, broker, and worker cannot read the canary or infer it from errors.
- [ ] 5.10 Add entitlement inspection and canary/log scanning that fails if production and development groups coexist in a release binary, a helper gains either group, or any credential/canary bytes reach diagnostics.

## 6. Build the fail-closed public release workflow

- [ ] 6.1 Add `scripts/release.sh` preflight for a clean intended revision, regenerated project parity, coherent versions, supported toolchain/architecture inputs, safe explicit paths, exact unambiguous Developer ID Application identity/Team, and authenticated `notarytool` Keychain profile.
- [ ] 6.2 Make each release use a unique bounded stage under `dist/`, preserve all previously verified artifacts, disable shell tracing, and allowlist the nonsecret configuration passed to subprocesses.
- [ ] 6.3 Build the Release app, generate/freeze the manifest, perform complete pre-sign validation, execute inside-out signing, and perform complete post-sign validation before image construction.
- [ ] 6.4 Refactor `scripts/package-dmg.sh` into a run-owned noninteractive image builder that includes exactly the verified app, Applications link, and declared presentation resources and produces a versioned read-only compressed DMG without deleting unrelated output.
- [ ] 6.5 Sign the exact disk image with the configured distribution identity, verify its signature, and record the pre-submission SHA-256 and byte size.
- [ ] 6.6 Submit that exact DMG with `xcrun notarytool --keychain-profile`, wait for an accepted terminal result, retrieve bounded sanitized diagnostics, and fail closed on rejection, timeout, unavailable status, or hash/path drift.
- [ ] 6.7 Staple and validate the accepted ticket on the unchanged DMG, reject any post-submission reconstruction or mutation, and confirm the hash relationship recorded for publication.
- [ ] 6.8 Attach the final DMG read-only without executing content and re-run manifest/layout/Mach-O, individual signature/entitlement/designated-requirement, strict recursive signature, staple, and applicable `spctl` Gatekeeper assessments on the downloadable image and embedded app.
- [ ] 6.9 Emit an allowlisted verification record with artifact hash/size, versions, architectures, source/manifest hashes, certificate metadata, Team ID, notarization submission/status, staple, Gatekeeper, and toolchain results while excluding authentication material and environment dumps.
- [ ] 6.10 Atomically publish only the fully verified versioned DMG and matching verification record; add failure injection at every preflight/build/validate/sign/image/notary/staple/mount/assessment/publish boundary proving failed candidates cannot replace the last verified release.

## 7. Prove release readiness and document operations

- [ ] 7.1 Add credential-free CI lanes for manifest determinism, complete synthetic packaging, Mach-O closure, signature/entitlement fixtures, Keychain query/migration logic, and secret/canary leakage scanning.
- [ ] 7.2 Add a protected/manual signed integration lane that exercises Apple Development nested identities and entitlement denials without exposing production signing or notarization credentials to ordinary pull-request jobs.
- [ ] 7.3 Run formatting, project-generation, first-party analysis, vendored QuickJS audit, foundation/native/UI, package, sandbox-containment, sanitizer, and strict OpenSpec checks with no hidden or newly normalized failure.
- [ ] 7.4 Produce a disposable real Developer ID release candidate, notarize and staple it, and verify the mounted downloadable artifact on a clean supported macOS account or machine without source-tree paths, development certificates, or local non-system libraries.
- [ ] 7.5 Document local-build labeling, release prerequisites, Keychain-profile provisioning, operator commands, failure recovery, evidence review, certificate/notarization incident handling, versioning, and older-build reconnection after credential migration without including secrets.
- [ ] 7.6 Keep public/community package import disabled in production and add a release gate proving both this change and `sandbox-javascript-execution` are implementation-verified before any later package-trust feature can enable it.
- [ ] 7.7 Run `openspec validate --changes --strict`, review the implementation against both Wave 4 delta specs, and leave release publication disabled until all checklist evidence is complete.
