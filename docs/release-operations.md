# Release operations

`./scripts/build.sh` produces an ad-hoc signed **local-only** `dist/Jort.app`.
It is useful for development and structural/package validation, but is not a
publisher-signed release, is not notarized, and must not be uploaded or
described as Gatekeeper-ready.

Only `./scripts/release.sh` may create a public artifact. It takes an exact
Developer ID Application identity, the expected Team ID, a non-secret path to
the reviewed production provisioning profile, and the name of a pre-provisioned
`notarytool` Keychain profile. Those are selectors, not secrets:
never pass passwords, API keys, private keys, or Keychain-item data on a command
line, in environment dumps, or into release evidence.

## Prerequisites and Keychain profile

Use a clean checkout at the intended revision, the repository-pinned XcodeGen,
supported Xcode/macOS toolchain, an unambiguous valid Developer ID Application
certificate for the expected Team, a production provisioning profile whose
application identifier is exactly `TEAMID.dev.jort.editor` and whose Keychain
group allowlist authorizes `TEAMID.dev.jort.editor.credentials` through either
that exact entry or a safe Team-scoped trailing wildcard such as `TEAMID.*`, and a Keychain
profile authenticated for notarization. Provision the notary profile on the protected release machine using
Apple's `xcrun notarytool store-credentials`; retain only its nonsecret profile
name in release automation. Confirm the notary profile there with `notarytool history`
or the release preflight. Do not export a Keychain, certificate private key, or
profile secret into this repository or CI logs.

The selected certificate’s SHA-1 must appear exactly once in the profile’s
`DeveloperCertificates`; the release preflight rejects a profile/certificate
mismatch before the build. Production profiles must be macOS all-devices
profiles and contain no `ProvisionedDevices` list.

The protected Apple Development integration runner also needs an installed
development profile with application identifier `TEAMID.dev.jort.editor` whose
Keychain group allowlist authorizes `TEAMID.dev.jort.editor.development.credentials`
through that exact group or a safe Team-scoped trailing wildcard. Configure its filesystem
path as the protected environment variable `JORT_DEVELOPMENT_PROVISIONING_PROFILE`;
pair it with `JORT_APPLE_DEVELOPMENT_IDENTITY` and `JORT_DEVELOPMENT_TEAM_ID`.
The build rejects a missing, expired, wrong-Team, wrong-app-ID, malformed or
foreign-Team wildcard, non-macOS profile, wrong certificate, or wrong
development/distribution profile kind before invoking Xcode. Development profiles
must explicitly authorize this Mac; distribution profiles must authorize all devices.
It embeds
the accepted profile before its final inside-out Apple Development signing pass
and requires a strict code-signature verification before packaging.

The profile is only an authorization allowlist, so unrelated exact entries may
also be present. The signed main app always claims exactly one
environment-specific group; it never substitutes a wildcard, and the broker and
worker receive neither group. The main app's production Keychain group is resolved from the release Team ID.
Local and Apple Development qualification use a distinct development namespace.
The broker and worker never receive either credential group.

## Operating a release

Run the release command on the protected release environment with the approved
identity, Team ID, and profile selectors. It must reject a dirty source tree,
stale generated project, ambiguous identity, mismatched Team, incoherent
version/build, unavailable profile, or unsafe output path. Shipping version/build
coherence is resolved during preflight, before compilation.

Preflight scans all tracked repository inputs for private-key headers and known
OpenRouter, GitHub, Slack, AWS access-key, and bearer-JWT encodings. Manifest
generation and loading repeat the scan on manifest fields. The scan rejects
files over 16 MiB, repositories over 512 MiB or 100,000 paths, and escaping paths;
it never prints matching bytes or filenames. These high-confidence patterns do
not claim to recognize every arbitrary password. Keep credentials outside the
repository even when their format is not recognized.

The checked-in manifest schema is enforced at runtime without remote references
or additional packages. Each code object's reviewed entitlement source path and
SHA-256 are bound into the manifest. Signing and verification also enforce an
independent exact capability allowlist: one app credential group, sandbox-only
broker, sandbox-plus-inherit worker, and entitlement-free frameworks. Editing
JSON or entitlement files alone cannot broaden that authority.

Review the final versioned DMG with its verification record: artifact hash and
size, app/build versions, source and manifest hashes, architectures, certificate
metadata, Team ID, notarization result, staple validation, Gatekeeper assessment,
and toolchain identity must all be present. The record omits authentication data.

First qualify a disposable candidate while publication remains policy-disabled:

```sh
./scripts/release.sh \
  --revision 0123456789abcdef0123456789abcdef01234567 \
  --identity 0123456789ABCDEF0123456789ABCDEF01234567 \
  --team-id ABCDE12345 \
  --provisioning-profile /secure/profiles/Jort-Developer-ID.provisionprofile \
  --notary-profile jort-release \
  --architectures arm64 \
  --candidate
```

The candidate workflow performs the security-relevant clean-environment checks
without relying on the current login account: it builds from the selected clean
revision, accepts only the exact Developer ID identity, validates the complete
Mach-O dependency closure, rejects source-tree and non-system external library
paths, mounts the finished DMG read-only, and repeats signature, entitlement,
manifest, staple, and Gatekeeper verification against the mounted app. A launch
smoke test from a separate macOS account or machine is useful defense in depth,
but is optional when managed-device policy prevents creating a test account; it
does not replace any automated release gate.

Replace every example selector with the exact reviewed revision, Developer ID
Application certificate SHA-1, Team ID, provisioning-profile path, and pre-provisioned notary profile. After the
signed-release and sandbox qualification evidence is independently reviewed,
the committed release policy may be updated in a separate reviewed change; only
then may the same command run without `--candidate` to atomically publish.

Credential-free local builds carry development-only debugging and library-load
exceptions so separately ad-hoc-signed frameworks can launch. They carry no
credential access group. The protected Apple Development lane replaces those
local exceptions with the development credential group and embeds its reviewed
development provisioning profile; public release signing embeds only the
production profile and uses only the production group. Neither development
policy is distributable.

For every non-accepted notarization response with a submission ID, the retained
stage includes a bounded `notary-diagnostics.json`. Rejected or invalid
submissions include sanitized allowlisted issue severity, code, and message
fields from the terminal log; in-progress or unavailable statuses retain only
fixed ID/status/unavailable metadata. It never retains raw notarytool output,
paths, URLs, profile data, or credentials. If a stage fails, preserve its
bounded sanitized evidence and do not rename, upload, or promote the candidate.
A failed stage must leave the prior verified artifact untouched. Fix the
specific condition, start a new run-owned stage, and rerun the complete
workflow; do not re-sign, reconstruct, or staple different bytes under a prior
record.

## Incidents, versions, and rollback

On suspected certificate compromise, expiration, Team mismatch, notarization
rejection, or unexpected entitlement/signature result, stop publication, revoke
or replace credentials through Apple as appropriate, and preserve only sanitized
release evidence. Reissue a new versioned candidate after re-establishing the
exact identity and notarization preflight; never weaken checks to recover a
release.

Version and build values must agree across every shipped Info.plist and record.
Roll back by serving a previously verified versioned DMG, not by modifying a
published image. Builds older than the protected credential migration may require
the user to reconnect; they must not recreate legacy Keychain storage or copy a
protected credential back automatically.

## Community-import gate

Public/community tool-package import remains disabled in production. It may be
considered only in a separately reviewed package-trust change after both
`sandbox-javascript-execution` and
`establish-signed-release-and-app-identity` are implementation-verified with
their recorded evidence. A signed release alone does not enable discovery,
download, installation, or trust of third-party code.
