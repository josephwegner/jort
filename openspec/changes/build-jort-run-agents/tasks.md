## 1. Agent, provider, and run models

- [ ] 1.1 Define typed agent/provider IDs, declarations, context modes, capabilities, immutable manifests, consent records, run states, and bounded diagnostics.
- [ ] 1.2 Add agent, provider-configuration, run-record, consent, and agent-provenance migrations and complete snapshot/revision validation.
- [ ] 1.3 Implement lazy registries and Keychain-backed provider credentials with redacted logging and dependency injection.
- [ ] 1.4 Add migration, schema, malformed-record, credential-isolation, interrupted-run, retention, and recovery tests.

## 2. Agent invocation and visible context

- [ ] 2.1 Extend completion and committed-token parsing for exact registered `@agent` names without affecting unmatched text or IME.
- [ ] 2.2 Implement prompt-only default, full-line, and declared bounded before/after range calculation using stable anchors.
- [ ] 2.3 Render exact context shading and labels from the same pending range model used to build the manifest.
- [ ] 2.4 Build fresh whole-document and exact-revision preview/confirmation flows with no persistent allow option.
- [ ] 2.5 Freeze exact UTF-8 text, generation, anchors, hashes, identities, capabilities, and consent into one immutable manifest on Run.
- [ ] 2.6 Add mid-line, Unicode, edit-before-run, context-toggle, whole-document denial, repeated-consent, keyboard, and accessibility tests.

## 3. Provider boundary and fake concurrency harness

- [ ] 3.1 Define the bounded cancellable `ModelProvider` request/response and typed availability/failure contract.
- [ ] 3.2 Implement a deterministic fake delayed provider supporting success, failure, timeout, cancellation races, malformed output, and limit violations.
- [ ] 3.3 Implement one OpenAI-compatible `URLSession` provider with explicit endpoint, Keychain credential, timeout, response cap, cancellation, and no tool calls.
- [ ] 3.4 Prove provider registries and network clients do not initialize at launch, editing, search, history, or deterministic-command use.
- [ ] 3.5 Add offline, missing-credential, endpoint, TLS/network, timeout, cancellation, malformed-response, redaction, and output-limit tests.

## 4. Run lifecycle and UI

- [ ] 4.1 Implement actor-owned run transitions with exactly one terminal state and rejection of late callbacks.
- [ ] 4.2 Add fixed-height viewport-bounded pending, running, failure, conflict, and completed overlays with explicit Cancel.
- [ ] 4.3 Persist bounded operational state, mark running records interrupted on relaunch, and implement manual Retry as a new manifest and run.
- [ ] 4.4 Preserve editor selection, viewport, typing, search, history, and command operation through every run-state update.
- [ ] 4.5 Add concurrent editing, multiple runs, cancellation race, relaunch, retry, offscreen overlay, focus, and accessibility tests.

## 5. Safe completion and conflict handling

- [ ] 5.1 Capture invocation `LineID`, line-relative ranges, neighboring boundary identity, and SHA-256 hashes needed for insertion validation.
- [ ] 5.2 Rebase unchanged invocation lines moved by unrelated edits and reject automatic mutation when invocation or boundary validation fails.
- [ ] 5.3 Build conflict preview with Insert at Current Resolved Boundary, Copy Output, and Discard actions and no overwrite path.
- [ ] 5.4 Commit bounded complete output through the atomic transaction API with metadata, provenance, Undo/Redo, persistence, and history boundary.
- [ ] 5.5 Implement Merge as provenance removal and ensure deletion remains an explicit ordinary text mutation.
- [ ] 5.6 Add property and integration tests for edits above, within, and after invocation/context, split/join, deleted anchors, duplicate text, undo, write failure, and history restore.

## 6. Security, performance, and release gates

- [ ] 6.1 Add authority tests proving providers receive only manifest ranges and agents cannot invoke deterministic commands, scripts, external processes, filesystem, capture, or undeclared network endpoints.
- [ ] 6.2 Benchmark pending decoration, context shading, running overlays, concurrent editing, hashing, rebase, and insertion with `CrawlLargeDocument`.
- [ ] 6.3 Re-run all prior launch, typing, scrolling, persistence, recovery, gutter, palette, history, search, command, IME, and accessibility gates with providers unavailable and during a delayed run.
- [ ] 6.4 Complete keyboard-only and VoiceOver flows for context review, consent, Run, Cancel, failure, conflict, Merge, and Retry.
- [ ] 6.5 Audit the finished Run MVP to confirm there is no token streaming, chat transcript, autonomous/background execution, automatic retry, JavaScript runtime, external command, capture, connector, or permanent whole-document/history consent.
