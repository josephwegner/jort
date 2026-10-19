## 1. Blocking signed containment and runtime prototype

- [ ] 1.1 Inventory current production signing, sandbox, storage/recovery locations, IPC authentication, and in-flight manifest/protocol changes; record the threat model and deny-probe targets.
- [ ] 1.2 Prototype separate signed network-disabled/network-enabled sandbox supervisors and a disposable inherited-sandbox bootstrap that replaces itself with a selected interpreter using public macOS APIs.
- [ ] 1.3 Exercise system shell and installed Python/Homebrew/venv fixtures for JSON stdin, stdout, imports, TLS, resource scopes, and runtime compatibility; record supported and rejected layouts without broad directory exceptions.
- [ ] 1.4 Prove script snapshot and race-resistant interpreter/runtime identity enforcement with replacement/symlink tests; document the resource trust-unit invalidation strategy.
- [ ] 1.5 Prove denied Jort database/WAL/recovery/settings/app access, credentials, IPC impersonation, Apple Events, debugging, environment/descriptor leakage, and network denial in the no-network profile.
- [ ] 1.6 Prove process restrictions, no surviving descendants, termination/reaping, and cleanup under supervisor death; reject process-group-only cleanup as sufficient evidence.
- [ ] 1.7 Review prototype evidence and make an explicit go/no-go decision. Stop and revise design/specs if any required boundary cannot be enforced; do not proceed with an unsandboxed fallback.

## 2. Contracts and local authorization

- [ ] 2.1 Add a nonconflicting opt-in manifest schema for bounded script declarations/selectors and requested network profile; preserve all current package schemas and model behavior.
- [ ] 2.2 Define primitive exec payload/result/error and protocol-v3 frame contracts with exact fields, lengths including escaping overhead, IDs, phase, sequence, and existing correlation identity.
- [ ] 2.3 Implement local approval persistence bound to tool/script/interpreter/runtime/profile identities, with no automatic approvals on import, migration, save, or restore.
- [ ] 2.4 Implement exact selector lookup, immutable script capture, approved-resource overlap rejection, launch identity verification, and fail-closed reapproval handling.
- [ ] 2.5 Add contract/authorization tests covering unknown fields, path syntax, malformed/oversized values, stale approvals, resource changes, revocation, and denied model usage.

## 3. External supervisor and disposable runner

- [ ] 3.1 Turn the accepted prototype into signed private helper targets/profiles with explicit entitlements and mutually authenticated XPC; keep the feature disabled.
- [ ] 3.2 Implement fixed supported interpreter adapters, minimal cwd/environment, descriptor hygiene, scoped read authority, per-run scratch, and verified limits before input delivery.
- [ ] 3.3 Implement concurrent bounded stdin/stdout/stderr handling, UTF-8/line/byte validation, exit interpretation, raw-stderr discard, and sensitive-data-free typed diagnostics.
- [ ] 3.4 Implement two-run global admission, bounded cancellable FIFO, one outstanding/four total calls per invocation, shared 25-second external and at-most-30-second overall deadlines, and 20-second runner CPU caps.
- [ ] 3.5 Implement cancellation/revocation/overflow/watchdog termination, escalation, reaping, supervisor-loss behavior, and exactly one terminal outcome without retry.
- [ ] 3.6 Add signed runner tests for normal/empty/nonzero/crash/hang/flood/invalid-output cases, inherited authority, descendants, and bootstrap/setup failure.

## 4. JavaScript asynchronous capability bridge

- [ ] 4.1 Add negotiated v3 capability request/reply framing through worker, broker, transport, and independent host policy router; retain protocol-v2 contract-2 and contract-1-adapter one-request/one-result behavior, maximum captured-data bounds, and typed action semantics.
- [ ] 4.2 Add execution-only frozen `jort.exec` with strict JSON snapshot serialization that avoids getters/custom serialization and rejects cycles/unsupported types/depth/size violations.
- [ ] 4.3 Refactor QuickJS promise pumping to await bounded authenticated completions when local jobs are empty while preserving cancellation, CPU/heap/stack limits, and no direct OS bindings.
- [ ] 4.4 Integrate invocation/generation ownership and phase gating; reject module-initialization/validation calls, duplicates, forged approvals, stale replies, parallel calls, and excess call counts before effects.
- [ ] 4.5 Add adversarial protocol/async tests, no-output-on-failure assertions, broker-loss handling, and existing pure-JavaScript/model/native-action regression coverage, including maximum-size contract-2 metadata and contract-1 adaptation.

## 5. Tools Settings and explicit effect-aware execution

- [ ] 5.1 Add local script/interpreter/resource selection and approval/revocation UI showing tool identity, input scope, outbound-network breadth, unsupported runtimes, and external-effect warnings.
- [ ] 5.2 Require explicit user submission for external-capable tools, including zero-argument generators; ensure completion acceptance, previews, validation, save, restore, rendering, Merge, and Undo/Redo never dispatch.
- [ ] 5.3 Add interrupted/unknown external-outcome presentation and explicit-rerun duplicate-effect warning; keep document undo and external effects separate.
- [ ] 5.4 Add UI/lifecycle tests for consent changes, generation edits, queued cancellation, late replies, document restoration, and no implicit retries/replays.
- [ ] 5.5 Document the API, supported-runtime matrix, user-owned integration secret configuration, restrictions, error semantics, and a Python JSON-stdin/stdout Slack-sync example without embedded credentials.

## 6. Release evidence and final integration

- [ ] 6.1 Extend signing/entitlement/dependency audits and validation-dispatched native containment probes for both external profiles while retaining the existing JavaScript denial suite.
- [ ] 6.2 Run focused checks through `./scripts/validate` during implementation and inspect bounded summaries; verify every new spec scenario has test evidence.
- [ ] 6.3 Obtain independent security review of prototype evidence, approved-resource lifetime/identity, duplex IPC, consent, lifecycle cleanup, and fail-closed paths; resolve blocking findings before enabling.
- [ ] 6.4 Enable only supported configurations after release-like evidence passes; verify rollback disables dispatch/cancels work without migrating existing tools or replaying effects.
- [ ] 6.5 After the final implementation change, run `./scripts/validate gate` once and record current results plus signed/manual evidence and any unsupported-runtime limitations.
