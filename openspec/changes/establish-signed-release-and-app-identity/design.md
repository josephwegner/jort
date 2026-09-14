## Context

The current `scripts/build.sh` builds Release configuration and `scripts/package.py` copies it into `dist/Jort.app`, but project-wide settings disable signing and the packager explicitly labels the result unsigned and local-only. Validation names only three frameworks even though the current app embeds five, does not prove Mach-O closure or sealed resources, and is disconnected from the target graph. The reviewed artifact consequently has no stable Team ID or designated requirement, fails strict signature validation, and cannot carry trustworthy notarization evidence.

Wave 2 and Wave 3 intentionally change the final graph before distribution is fixed. The application will compose `JortToolContracts` and `JortToolRuntime`; a private, engine-free `JortJavaScriptBroker.xpc` will launch a disposable `JortJavaScriptWorker`; and only that worker may link or load QuickJS. The release workflow must derive its expectations from that generated graph instead of preserving today's framework list or embedding `JortJavaScript.framework` by habit.

The current credential store requests `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` but does not set `kSecUseDataProtectionKeychain`, so macOS does not apply the requested Data Protection Keychain accessibility policy. A Developer ID code identity is also needed to make a production access group and application requirement stable. OpenRouter credentials authorize billable use, making release identity and credential migration one security boundary.

## Goals / Non-Goals

**Goals:**

- Produce one repeatable, fail-closed Developer ID distribution workflow whose final disk image, app, nested code, resources, identities, entitlements, and notarization are independently verifiable.
- Keep routine development credential-free and visibly separate from public release production.
- Generate one authoritative package/identity manifest from the final generated target graph and make every packaging, signing, and verification stage consume it.
- Preserve the Wave 3 broker/worker sandbox and QuickJS-linkage boundary while enabling Hardened Runtime on all shipping code.
- Give production credentials a stable Data Protection Keychain namespace available only to the main application identity, with fail-safe legacy migration and a distinct development namespace.
- Retain bounded, useful release evidence without printing or persisting authentication material or credential contents.

**Non-Goals:**

- App Store packaging, Mac App Store receipt behavior, or installer packages.
- Enabling App Sandbox on the main application or relocating existing document/settings stores into an app container.
- Changing the Wave 3 broker/worker protocol, sandbox authority, process limits, or one-run lifecycle.
- Adding package discovery, download, trust prompts, automatic updates, or public/community imports.
- Requiring a Developer ID certificate or notarization profile for ordinary local builds and non-release tests.
- Claiming bit-for-bit reproducibility across timestamped signatures and Apple's notarization service.

## Decisions

### Separate local builds from public release production

`scripts/build.sh` remains the routine developer entry point. It generates the project, builds with no external signing or notarization secret, packages through the common structural validator, and prints an unambiguous local-only result. It may apply deterministic ad-hoc signing where the Wave 3 development helper topology needs signed code identities and entitlement tests, but it never selects a Developer ID identity, reads a notarization profile, creates a release-named artifact, or claims Gatekeeper readiness.

Add `scripts/release.sh` as the only public-distribution entry point. It accepts nonsecret selectors for the expected Developer ID Application identity, Team ID, and pre-provisioned `notarytool` Keychain profile. It fails before building when the source tree is not the exact intended clean revision, version/build values are missing or inconsistent, project generation is stale, the selected identity is absent or ambiguous, the certificate's Team ID differs from the expected Team ID, the notarization profile cannot authenticate, required tools are missing, or the output/staging boundary is unsafe.

The script uses a unique temporary staging root under `dist/`, never mutates a previously verified release, and publishes the versioned final disk image plus a nonsecret verification record only after every final check succeeds. A failed run preserves bounded sanitized diagnostics and the last verified artifact, but its stage is never promoted or labeled distributable.

A single script with optional signing was rejected because a forgotten flag can turn a local artifact into an apparently public one, or skip a required release step. Requiring release credentials in `build.sh` was rejected because ordinary development must remain available without publisher authority.

### Generate one release manifest from the resolved project graph and policy

Introduce a versioned machine-readable release-manifest generator. It reads the final `project.yml`, generated Xcode target graph, selected Release build settings, Info.plists, resource declarations, and a small committed role policy. It emits one immutable manifest for the run before packaging. The role policy names security facts that cannot be inferred from dependency edges alone: main app, framework, XPC broker, disposable worker, allowed system dependency roots, required/prohibited entitlement sets, QuickJS-bearing role, and required public resources.

For every shipping object the manifest records its exact bundle-relative path, role, code/bundle identifier, executable name and mode, containment parent, expected architectures, Team-ID relationship, Hardened Runtime requirement, entitlement policy, and allowed Mach-O dependency/rpath closure. It also records application versions, icon and bundled-tool resource inventory, expected Info.plist values, forbidden stale paths/roles, manifest schema version, source revision, project/configuration hash, and toolchain version.

The fixed production identifiers are `dev.jort.editor` for the app, `dev.jort.editor.javascript-broker` for the XPC service, and `dev.jort.editor.javascript-worker` for the worker code object. Framework identifiers and paths come from the resolved post-Wave-3 graph. A rename is an explicit manifest/policy and peer-requirement migration, not an inferred packaging change.

Generation fails if a shipping target lacks a declared role, two objects claim the same path or identifier, an expected dependency is not embedded, a resource destination collides, or the resolved graph still embeds an obsolete engine framework. `scripts/package.py`, local packaging tests, `release.sh`, disk-image creation, and final verification consume this manifest rather than carrying independent framework/resource lists.

Using the current hand-maintained list was rejected because it has already omitted two frameworks and cannot follow the XPC extraction. Generating expectations from the built bundle alone was rejected because a compromised or incomplete output cannot define its own correctness.

### Validate structure and dependency closure before signing

The packaging validator constructs a fresh staged app and validates it without following unexpected symbolic links. It requires exactly the manifest's executable code locations, Info.plist identities and versions, public resources, bundled tool tree, executable modes, and architecture set; rejects undeclared executable/Mach-O content and stale targets; and hashes or inventories sealed non-code resources so later stages can prove they did not change.

For every Mach-O it enumerates load commands and `LC_RPATH` values, resolves `@rpath`, `@loader_path`, and `@executable_path` from that object's actual location, and requires each non-system dependency to resolve to exactly one manifest-declared nested object. Dependencies outside the bundle are allowed only from an explicit platform-system allowlist. QuickJS/JortJavaScript symbols, load commands, and runtime linkage are permitted only in `JortJavaScriptWorker`; the app, frameworks, and broker must remain engine-free.

Validation runs before any release signing, again after app signing, and again against the app mounted from the final disk image. No code, resource, plist, permission, extended attribute relevant to signing, or bundle layout may change after its containing signature is applied.

### Use stable identities and deliberate inside-out Hardened Runtime signing

Release configuration no longer inherits a global `CODE_SIGNING_ALLOWED = NO`. Shipping code enables Hardened Runtime and is signed with the selected Developer ID Application identity, secure timestamps, and the manifest's target-specific entitlements. The release script sorts declared code by containment depth, signs leaf frameworks and the worker first, then the containing XPC service, remaining nested code, and finally `Jort.app`. It never uses `codesign --deep` to apply signatures.

The worker receives the Wave 3 `app-sandbox` plus `inherit` keys and no JIT, unsigned-executable-memory, disable-library-validation, network, file, Keychain-group, Apple Events, device, app-group, or temporary-exception entitlement. The broker receives its independent App Sandbox and the Wave 3 explicit denial-by-omission policy. Frameworks receive no authority-bearing entitlements. The main app receives only its production Keychain access group and any separately justified non-sandbox entitlement; it explicitly does not receive `com.apple.security.app-sandbox` in this release.

After each signature, verification extracts the code identifier, Team ID, designated requirement, entitlements, secure timestamp, and Hardened Runtime flag. Every shipping object must have the expected identifier and Team ID relationship, and the broker's caller/worker peer requirements must resolve to the exact production identifiers plus the same Team ID. The final recursive `codesign --verify --deep --strict --verbose=4` is an additional closure check only after individual checks pass.

Ad-hoc outer signing was rejected because it supplies no publisher identity or notarizable chain. Enabling broad Hardened Runtime exceptions to ease QuickJS integration was rejected because the worker does not require JIT and Wave 3 prohibits library-validation exceptions.

### Keep the main app outside App Sandbox for the initial direct release

The first public build is Developer ID signed, notarized, and hardened, but the main application's release entitlements must omit App Sandbox. Existing Application Support paths, recovery exports, OpenRouter networking, file-menu behavior, and Keychain migration therefore do not acquire an implicit container migration. The JavaScript broker remains independently sandboxed and its child inherits that restricted authority.

This is an explicit boundary, not a claim that main-app sandboxing has no value. Enabling it later requires a separate proposal covering container paths, existing-store migration and rollback, outbound network scope, user-selected recovery export, security-scoped access, Keychain groups, and recovery/private-data guarantees. Treating App Sandbox as a release checkbox was rejected because it can strand existing data or silently broaden entitlements to regain behavior.

### Publish a signed, notarized disk image and verify the downloadable bytes

After the signed app passes its checks, the release workflow creates a new read-only compressed versioned DMG from a controlled staging directory, with only the manifest-declared app, Applications link, and presentation resources. It signs the disk image with the configured distribution identity, submits that exact DMG through `xcrun notarytool` using the named Keychain profile, waits for an accepted result, and staples and validates the ticket on the final DMG.

Final verification operates on the bytes that would be uploaded: verify the DMG signature and staple, attach it read-only without executing content, re-run manifest/layout/Mach-O and individual signature/entitlement checks on the mounted app, run strict recursive signature verification, and require `spctl` Gatekeeper assessment of both the distribution image and embedded application in their applicable modes. It records SHA-256, byte size, version/build, architectures, source revision, manifest hash, identity certificate fingerprint and expiry, Team ID, notarization submission ID/status, staple validation, Gatekeeper results, and verification toolchain in a sanitized report.

Merely trusting successful `codesign` or `notarytool submit` exit status was rejected because later packaging can invalidate the app and a submission can be rejected asynchronously. Verifying only the pre-DMG app was rejected because the downloadable artifact is the security boundary delivered to users.

### Move credentials into identity-scoped Data Protection Keychain namespaces

Define explicit, compile-time production and development credential policies. Production uses service `dev.jort.editor.openrouter.v2`, account `openrouter`, and access group `<ApplicationIdentifierPrefix>dev.jort.editor.credentials`; release verification requires the prefix's Team-ID component to match the configured Team ID. Development uses a different service, account, and access-group suffix (`dev.jort.editor.development.openrouter.v2`, `openrouter-development`, and `dev.jort.editor.development.credentials`) and can never fall back to the production query.

Every add, exact read, update, delete, migration verification, and cleanup query sets `kSecUseDataProtectionKeychain: true` and `kSecAttrSynchronizable: false`; created/replaced items set `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and the policy's exact access group. Query construction is centralized so an operation cannot accidentally drop a selector. Runtime receives only the credential bytes returned through the existing narrow interface and never persists them elsewhere.

The main production app alone carries the production `keychain-access-groups` entitlement. Broker and worker manifests explicitly prohibit that entitlement, and other frameworks do not independently access Security. Development/test signing uses only the development group. Release validation fails if a production binary contains the development group or if any nested helper contains either credential group.

Relying on the legacy Keychain ACL was rejected because it does not apply the requested accessibility class and is unstable without a designated application identity. Sharing a group with helpers was rejected because QuickJS containment must not inherit credential authority.

### Migrate legacy items as a single-flight, verified copy then delete

The credential actor first queries the protected environment-specific item. If none exists, the production app alone may query the exact legacy service/account item without a Data Protection selector, validate the bounded UTF-8 credential, add the new protected item, read it back through the complete protected query, and compare exact bytes before deleting the legacy item. It then confirms the protected item still reads and the exact legacy item is absent. Every operation is single-flight with connection reads/replacements so a provider cannot observe a partial migration.

Any read, add/update, verification, or delete failure leaves the legacy item untouched when the replacement has not been proved, returns a typed actionable Keychain/migration state, and logs no secret. If a verified protected item and a different legacy item coexist, Jort deletes neither and requires an explicit reconnect/cleanup decision; it never guesses which credential authorizes billable use. If legacy deletion alone fails after a matching protected copy is verified, Jort uses the protected item but reports and retries bounded legacy cleanup without recreating it.

Development builds never query or migrate the production legacy service. An older build rolled back after migration may appear disconnected because the legacy item has been deliberately removed; rollback does not copy a protected secret back into legacy storage, and the user may reconnect in the older build if necessary.

### Prove identity denial with signed canaries and keep logs secret-free

Unit tests verify complete query dictionaries and every migration failure boundary with an in-memory Security adapter. Signed integration fixtures use random disposable canary values, never a real OpenRouter credential. The correctly signed main-app test host can create/read/delete the canary in the corresponding test group; a helper with a different identifier and no authorized group, the broker, and the worker must receive an authorization/not-found result and must not learn the bytes. Entitlement inspection separately proves the group is absent even if a test environment cannot launch a negative probe.

Release commands run without shell tracing. They accept a Keychain profile name rather than passwords, private keys, or authorization tokens; redact command output and home paths where needed; and reject secret-looking release inputs in repository files or manifest fields. Notarization logs and verification records may contain hashes, certificate metadata, identifiers, statuses, and bounded paths, but never environment dumps, Keychain contents, OAuth material, or signing private-key data.

## Risks / Trade-offs

- **Risk: The generated manifest and Xcode graph disagree because generation logic is incomplete.** → Cross-check source declarations, resolved build settings, and the staged bundle; reject every undeclared shipping target and maintain malformed/missing/stale fixture tests.
- **Risk: A signing command silently applies a broader entitlement or identity than intended.** → Sign each manifest object explicitly, extract and compare its effective signature afterward, and make same-Team/exact-identifier checks release-blocking.
- **Risk: Notarization succeeds for bytes other than those finally published.** → Hash the submitted DMG, staple that same path, prohibit reconstruction after submission, and repeat verification and hashing immediately before atomic publication.
- **Risk: Main-app non-sandboxing leaves ordinary user-account authority available to first-party code.** → Keep untrusted native engine code in the minimal broker/worker sandbox, enable Hardened Runtime, preserve narrow provider contracts, and require a separate main-sandbox migration design before changing this boundary.
- **Risk: Legacy Keychain migration loses or chooses the wrong credential.** → Serialize migration, prove the protected copy byte-for-byte before deletion, preserve both on conflict, and surface cleanup/reconnect states instead of guessing.
- **Risk: Local ad-hoc signing cannot exercise a production access-group rule.** → Keep unit tests deterministic, use a configured Apple Development identity for signed integration gates, and require an actual Developer ID release verification before publication.
- **Risk: Detailed diagnostics leak release or user secrets.** → Disable tracing, use Keychain-profile references, allowlist report fields, sanitize external-tool output, and scan fixtures/logs for canary values.
- **Trade-off: Release production is slower and needs operator credentials.** → Keep it distinct from fast local packaging; security checks, notarization wait, and final mounted-artifact verification are mandatory only for publication.
- **Trade-off: A rolled-back build cannot read the new protected item.** → Never weaken or duplicate the new item automatically; document reconnection for rollback while the current build retains the protected credential.

## Migration Plan

1. Land the final Wave 2/3 target identifiers, nested locations, entitlements, and QuickJS-link boundary; keep public/community import disabled.
2. Add the release-role policy and manifest generator, then convert local packaging and fixtures to consume it. Add missing/stale/resource/mode/identifier/Mach-O/rpath/QuickJS-boundary fixtures before signing work.
3. Split project signing settings by Development and Release, add target-specific entitlement files, stable broker/worker identifiers, and credential-free ad-hoc or Apple Development integration-signing support.
4. Centralize production/development Keychain policies and complete Data Protection queries; add single-flight legacy migration, conflict/cleanup states, query-dictionary tests, and signed canary denial fixtures.
5. Add explicit leaf-to-root signing and per-object identity/Team/designated-requirement/entitlement/Hardened Runtime verification using disposable development fixtures first.
6. Add the isolated release preflight, controlled DMG creation/signing, `notarytool` submit-and-wait, stapling, read-only mount, Gatekeeper assessment, sanitized evidence, and atomic publication flow.
7. Run the complete release workflow with the real Developer ID identity and a disposable versioned release candidate. Verify on a clean supported macOS account/machine without local development certificates or source-tree dependencies.
8. Keep community/public import disabled until both this change and `sandbox-javascript-execution` pass their implementation verification; record that joint gate in release documentation.

Source rollback before a public release is ordinary. After credential migration, an older build does not receive an automatic legacy copy and may require reconnection. A rejected or failed release is never published; the last verified version remains untouched. Revoking an already published certificate or notarized artifact is an operational incident procedure outside source rollback and must use Apple's current revocation/distribution controls.

## Open Questions

None at proposal time. The concrete Team ID, certificate fingerprint, notarization Keychain-profile name, supported architecture set, and release version are validated operator/build inputs recorded per release rather than source-level unknowns. The application, broker, worker, service/account, and access-group suffixes above are the stable source policy.
