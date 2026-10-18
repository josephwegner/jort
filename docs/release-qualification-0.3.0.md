# Jort 0.3.0 release qualification

Review date: 2026-10-18. Scope: Apple Silicon (`arm64`) only. No Intel or
universal-binary qualification is claimed. Reviewers: Codex release coordinator
and separate read-only sandbox/host-shim reviewers.

## Tested Developer ID candidate

- Source revision: `d3d16d76fee17e51ed1ebf66f5cd8a27b0a0eeb1`.
- Version/build: `0.3.0` / `3`.
- Artifact: `Jort-0.3.0-3-macos.dmg`, 5,802,732 bytes.
- Artifact SHA-256: `92b68091ac08a07834441657604bf61282d15b0e07aa1ae2bcea00a1cc285b3e`.
- Manifest SHA-256: `bb7ba83606a2749f06ee611fcd9b3646028c62b4708d208980c71e02e8a9f5f7`.
- Candidate policy SHA-256 (before publication approval): `287fcafe168c4f38af119aaaf9609b054385196127ba94f7c58a159982c22098`.
- Developer ID certificate SHA-1: `CA9E6E04ACBDFEB37C58FA6006EA976A0A7E413C`.
- Team: `6HXL4HHSN4`.
- Notarization submission: `8f263a99-1af3-4d5c-b9ae-f17555e412be`, `Accepted`.
- Toolchain: Xcode 26.6, build 17F113.

The release coordinator independently recomputed the artifact/manifest/policy
hashes and matched the candidate revision to the clean checkout. The DMG
signature, notarization staple, and Gatekeeper disk-image assessment passed.
It was then mounted read-only at an isolated temporary path without launching
Jort. All ten embedded code objects passed strict identity, Developer ID
certificate, Team, Hardened Runtime, timestamp, entitlement, compiled peer-policy,
and recursive resource-seal verification. Manifest inventory, Mach-O dependency
closure, bundled artwork, and mounted-app Gatekeeper assessment passed.

The user installed and tested this candidate and confirmed it worked. The
restored installer presentation separately passed the desktop smoke test in
`.build-validation/20261018T140039Z-65680`: saved background/volume identity,
window geometry, and icon positions in the compressed read-only image.

## Sandbox qualification

Fresh local containment run `.build-validation/20261018T223622Z-6317` passed
48 tests, with the USB test explicitly skipped because the supported device
was not connected at that time. That skip is not counted as device-denial
evidence. The user subsequently connected a YubiKey for the protected-device
positive control and inherited-sandbox denial test.

Early runs using ordinary shell `JORT_CONTAINMENT_*` variables did not forward
the requested signing configuration into XCTest and are not accepted as Developer
ID evidence. In particular, the earlier functional USB pass is superseded by the
explicitly signed matrix below. Xcode's `TEST_RUNNER_` forwarding and a receipt
emitted only after strict signature validation remove that ambiguity.

The authoritative Developer ID run is
`.build-validation/20261018T225149Z-11020`: eight tests passed with zero skips
or failures. Its retained log contains 16 successful signature-verification
receipts with the same certificate SHA-1 and Team as the reviewed candidate.
It covers Apple Events control/denial, file read/write, network client/server,
disposable-Keychain and subprocess denials, native CPU-limit termination and
reaping, inherited Mach-capability cleanup, production-worker mapping/reaping,
heap exhaustion followed by a healthy fresh worker, signing-configuration
validation, and the USB positive-control/denial probe. The user enabled and
reconnected the YubiKey; macOS enumerated the exact Yubico service before this
run. The unsandboxed positive control opened and closed it, then the inherited
sandbox child was denied against the same service.

Every disposable fixture was signed with the selected certificate and checked
against an Apple-anchored Developer ID requirement and expected Team. The broker
and child fixtures use exactly the production broker/worker sandbox entitlements,
with no XCTest debugging exceptions; the independent Apple Events positive
control has its separate automation permission, not a broker/worker capability.
These are nonshipping test executables, not a modification of the candidate;
fixture signatures intentionally omit timestamps, unlike the verified
distribution artifact. Default ad-hoc signing is not substituted for this evidence.

These fresh results supersede the incomplete denial-matrix note in the archived
Wave 4 containment handoff. Historical signed-integration/credential-canary
evidence in `.build-validation/20261001T022753Z-24622` remains supplementary;
it does not replace the fresh native denial tests above.

## Approval and scope

The coordinator and independent reviewer completed the bounded policy/code and
evidence review with no actionable findings. The two qualification approvals and
publication switch are enabled. Public/community package import remains disabled;
app/helper entitlements, peer admission, system-library allowlists, and engine
configuration are unchanged.

The approved policy SHA-256 is
`2362fc0ae76571c044cd2b1485c6835c78c1209d95948cf61d9c2e8ac3a1fe53`.
The focused release fixtures passed in `.build-validation/20261018T225352Z-11411`,
including the explicit-Boolean publication approval matrix. The fresh full gate
after the final policy/code edit passed all nine checks in
`.build-validation/20261018T225517Z-12068`: formatting, generated project,
Foundation, native editor, packaging, first-party analysis, provenance-matched
QuickJS audit, isolated GUI tests, and built-bundle containment inspection.
No application/worker source or entitlement changes were made during approval.

## Dependency review

See the [October 18 QuickJS review](quickjs-security-review.md). The upstream
archive, imported inventory, complete local patch, and analyzer provenance match.
Known findings were assessed against the source-only host contract and
mandatory disposable-worker boundary. No dependency or baseline changes were
made. Public/community package import remains disabled.

## Publication handoff

This review does not upload a release or change a verified candidate's bytes.
The final review and validation are complete. Commit these changes, including
the new fixture header and review record, and run:

```sh
./scripts/release.sh --revision "$(git rev-parse HEAD)" --architectures arm64
```

The new revision is rebuilt, signed, notarized, stapled, mounted, and independently
verified by the pipeline before local publication. Upload the DMG from the
resulting `dist/Jort-0.3.0-3-macos/` directory, not a staging/intermediate image.
The accompanying verification JSON belongs in the retained release records.
