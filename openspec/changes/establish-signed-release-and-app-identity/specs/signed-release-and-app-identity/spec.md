## ADDED Requirements

### Requirement: Development builds remain separate from public releases
Jort SHALL provide a credential-free local build workflow that labels its output non-distributable and a distinct fail-closed public release workflow that is the only path permitted to claim a Developer ID, notarized artifact.

#### Scenario: Developer performs a routine local build
- **WHEN** `scripts/build.sh` runs without a Developer ID identity or notarization profile
- **THEN** it builds and structurally validates a local artifact without requesting release credentials
- **AND** labels the result local-only and does not give it a public-release filename or readiness claim

#### Scenario: Public release inputs are incomplete
- **WHEN** the release workflow lacks an exact Developer ID Application identity, expected Team ID, authenticated notarization Keychain profile, coherent version/build metadata, or safe staging destination
- **THEN** it fails before publishing an artifact
- **AND** does not fall back to ad-hoc signing, unsigned output, a different identity, or skipped notarization

#### Scenario: Public release source is not the intended revision
- **WHEN** tracked source or generated project state differs from the exact clean revision selected for release
- **THEN** the release workflow refuses to proceed
- **AND** reports the nonsecret source-state mismatch without modifying the last verified release

### Requirement: One generated manifest defines the shipping bundle
Jort SHALL generate one versioned package and identity manifest from the post-Wave-3 project graph, resolved Release settings, declared resources, and committed security-role policy, and every packaging, signing, and verification stage SHALL consume that manifest.

#### Scenario: Final target graph is resolved
- **WHEN** the manifest is generated for Release configuration
- **THEN** it records every shipping code object's exact path, role, identifier, executable, mode, architecture, containment, entitlement policy, Team relationship, Hardened Runtime requirement, and dependency policy
- **AND** records version metadata, public resources, bundled tools, forbidden stale roles, source/project hashes, and toolchain identity

#### Scenario: Shipping target has no declared security role
- **WHEN** the resolved graph contains an embedded executable, framework, XPC service, or helper that is absent from the release role policy
- **THEN** manifest generation fails closed
- **AND** no consumer infers expectations from the untrusted built bundle or a partial hard-coded framework list

#### Scenario: Post-sandbox graph is packaged
- **WHEN** the manifest describes the final JavaScript containment targets
- **THEN** it requires `JortJavaScriptBroker.xpc` and `JortJavaScriptWorker` at their declared nested locations and permits QuickJS linkage only in the worker
- **AND** rejects an obsolete embedded `JortJavaScript.framework` unless a later reviewed target policy explicitly declares a non-engine role for it

### Requirement: Package validation covers all declared content and dependencies
Jort SHALL validate the complete staged application before signing, after application signing, and again from the mounted final distribution image without allowing the artifact to define its own expected contents.

#### Scenario: Complete staged application is valid
- **WHEN** validation inspects the staged app
- **THEN** every manifest-declared code object, Info.plist value, icon, bundled tool resource, executable bit, architecture, and ordinary resource is present at the exact declared location
- **AND** no undeclared executable, Mach-O object, duplicate identity/path, stale code target, or colliding resource is present

#### Scenario: Nested dependency is resolved
- **WHEN** validation inspects each Mach-O load command and runtime search path from that object's actual bundle location
- **THEN** every non-system dependency resolves to exactly one manifest-declared nested object and every system dependency belongs to the explicit platform allowlist
- **AND** missing, ambiguous, unexpectedly external, or forbidden QuickJS/JortJavaScript linkage fails packaging

#### Scenario: Signed bundle content changes
- **WHEN** any declared resource, plist, executable permission, extended attribute relevant to signing, nested path, or code byte differs after its containing signature was applied
- **THEN** post-sign or mounted-image validation fails
- **AND** the altered artifact is never submitted or published

### Requirement: Production code has stable least-authority identities
Jort SHALL use stable production identifiers for the app (`dev.jort.editor`), JavaScript broker (`dev.jort.editor.javascript-broker`), and worker (`dev.jort.editor.javascript-worker`) and SHALL require the configured production Team ID and manifest entitlement policy for every shipping code object.

#### Scenario: Release code identity is inspected
- **WHEN** the app or any nested code object has been signed
- **THEN** its code identifier, Team ID, designated requirement, secure timestamp, Hardened Runtime flag, and effective entitlements match the manifest
- **AND** an absent, ad-hoc, mismatched, ambiguous, expired-for-signing, or unexpectedly broad identity fails the release

#### Scenario: JavaScript helper entitlements are inspected
- **WHEN** release verification examines the broker and worker
- **THEN** the broker has the independent minimal App Sandbox policy and the worker has exactly the Wave 3 sandbox/inherit authority without credential, network, file, app-group, Apple Events, device, temporary-exception, JIT, or library-validation exceptions
- **AND** the configured peer requirements identify the exact broker/worker identifiers and same Team ID

#### Scenario: Main application entitlements are inspected
- **WHEN** release verification examines the main app
- **THEN** it has Hardened Runtime and only the declared production credential access group and separately reviewed non-sandbox entitlements
- **AND** it does not contain `com.apple.security.app-sandbox` or silently relocate user data for the initial direct release

### Requirement: Shipping code is signed deliberately inside out
Jort SHALL sign each declared nested code object explicitly from the deepest leaves to the containing application using the selected Developer ID Application identity, secure timestamps, Hardened Runtime, and role-specific entitlements.

#### Scenario: Application signature is constructed
- **WHEN** the release workflow signs Jort
- **THEN** it signs leaf frameworks and the disposable worker before the containing XPC service, signs remaining nested code before `Jort.app`, and verifies each object immediately
- **AND** never uses recursive deep signing as a substitute for the manifest order

#### Scenario: Final recursive verification runs
- **WHEN** every individual code object has passed identity and entitlement checks
- **THEN** the workflow additionally runs strict recursive signature verification on the containing app
- **AND** treats any resource-seal, nested-code, or designated-requirement failure as release-blocking

### Requirement: The downloadable disk image is notarized and stapled
Jort SHALL create a controlled read-only versioned disk image from the verified signed app, sign the image, submit those exact bytes to Apple's notarization service, wait for acceptance, staple the accepted ticket, and validate the final downloadable artifact.

#### Scenario: Notarization is accepted
- **WHEN** the signed disk image is submitted through the configured `notarytool` Keychain profile
- **THEN** the workflow waits for an accepted terminal result, confirms the submitted hash matches the image that will be published, staples that image, and validates the staple
- **AND** performs no reconstruction or content mutation after submission

#### Scenario: Notarization is rejected or unavailable
- **WHEN** Apple rejects the submission, the wait ends unsuccessfully, the ticket cannot be stapled, or staple validation fails
- **THEN** the workflow fails closed with bounded sanitized diagnostics
- **AND** does not publish, rename, or label the candidate as a release

#### Scenario: Final artifact is assessed
- **WHEN** the stapled image is attached read-only for final verification
- **THEN** Jort revalidates manifest content, Mach-O closure, every individual signature and entitlement, strict recursive signature state, and applicable Gatekeeper assessments for the image and embedded app
- **AND** rejects a result that depends on source-tree frameworks, developer search paths, or locally installed non-system libraries

### Requirement: Release publication preserves prior verified artifacts
Jort SHALL build each candidate in a unique bounded staging location and SHALL atomically publish only a completely verified, versioned artifact without overwriting a prior verified release during a failed run.

#### Scenario: Candidate fails at any release stage
- **WHEN** build, manifest generation, validation, signing, image creation, notarization, stapling, mounting, Gatekeeper, or final verification fails
- **THEN** the candidate remains unpublished and cannot replace the last verified artifact
- **AND** cleanup is limited to the exact run-owned stage while bounded sanitized failure evidence remains available

#### Scenario: Candidate passes every release stage
- **WHEN** the exact final image and its verification record have passed all required checks
- **THEN** the workflow publishes them under versioned names and records their hashes together
- **AND** subsequent modification makes the published verification record invalid rather than silently blessing new bytes

### Requirement: Release evidence is complete and secret-free
Jort SHALL emit a bounded verification record sufficient to audit the release while excluding signing secrets, notarization authentication material, Keychain contents, OAuth values, environment dumps, and private-key data from source and logs.

#### Scenario: Release completes
- **WHEN** a candidate is published
- **THEN** its record includes artifact hash/size, version/build, architectures, source revision, manifest hash, certificate fingerprint/expiry, Team ID, notarization submission/status, staple result, Gatekeeper result, and verification toolchain
- **AND** contains no credential value or authentication material

#### Scenario: External signing or notarization tool reports an error
- **WHEN** the release workflow captures diagnostic output
- **THEN** it allowlists or sanitizes the retained fields, disables shell tracing, and refers to notarization credentials only by nonsecret Keychain-profile name
- **AND** never writes a password, API private key, token, OAuth credential, or raw Keychain item to the repository or release log

### Requirement: Community distribution stays gated on both security boundaries
Jort SHALL keep public/community tool-package import disabled until the sandboxed JavaScript execution change and this signed-release change have both been implemented and independently verified.

#### Scenario: Only one prerequisite is complete
- **WHEN** JavaScript containment is verified but public release identity is not, or release identity is verified but containment is not
- **THEN** production builds expose no public/community package import path
- **AND** release evidence identifies the unmet prerequisite without weakening either gate

#### Scenario: Both prerequisites are complete
- **WHEN** both changes have passed implementation verification
- **THEN** a later separately specified package-trust feature may treat the joint gate as satisfied
- **AND** this change alone does not enable discovery, download, installation, or trust of third-party code
