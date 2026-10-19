# Signed release qualification evidence

On 2026-09-30, a disposable arm64 Jort 0.3.0 (build 3) candidate was
built from isolated clean snapshot `1d7bf3621a332a994e2867ca2aa21a819e3b9c65`
with Xcode 26.6 (build 17F113). Publication remained disabled.

- Developer ID Application SHA-1: `CA9E6E04ACBDFEB37C58FA6006EA976A0A7E413C`
- Team ID: `6HXL4HHSN4`
- Notarization submission: `0dff6009-205d-4775-87f4-fe1434aee3fc` (`Accepted`)
- Manifest SHA-256: `6245bd113f6a16040c6e014df2fe77c91e3b00b07d9a547bf59ff1a0a691e4b2`
- Stapled artifact SHA-256: `5a2b6a170e57c942097d95143535f0ac873e5eea75f22306f94242c3b4fd4d95`
- Stapled artifact size: 4,893,712 bytes

The release workflow validated every shipping object's identifier, Team ID,
Developer ID certificate, designated requirement, Hardened Runtime flag, secure
timestamp, exact reviewed entitlement source/hash, effective entitlements, and
peer requirements. Preflight also validated the runtime manifest schema,
coherent product versions, and bounded tracked release inputs. It then mounted
the notarized DMG read-only and repeated manifest/layout, Mach-O closure,
signature, entitlement, staple, and Gatekeeper checks against the downloadable artifact.
Both the app and disk-image Gatekeeper assessments passed. Dependency closure
allowed only manifest-bundled code and declared system roots, so the result has
no source-tree dependency or locally installed non-system library dependency.

The release host is a managed corporate Mac whose policy prevents creating a
separate test account. A separate-account launch smoke test was therefore not
performed and remains optional before public distribution. This limitation does
not weaken the automated identity, dependency-closure, mounted-image, or
Gatekeeper checks described above.
