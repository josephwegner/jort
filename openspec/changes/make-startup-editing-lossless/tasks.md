## 1. Startup state and persistence barrier

- [ ] 1.1 Add a typed editor startup phase for loading, loaded reconciliation, ready, and editable recovery, with a deterministic observation hook for tests.
- [ ] 1.2 Replace startup decisions based on the `ready` Boolean or placeholder snapshot equality with the typed phase while keeping the text view immediately focused and editable.
- [ ] 1.3 Move the persistence readiness guard ahead of all `pending`, history, dirty-state, and scheduling mutation so pre-load snapshots are rejected without side effects.
- [ ] 1.4 Add headless delayed-load tests proving startup snapshots cannot displace the loaded baseline or become writable/history state after failure.

## 2. Lossless load reconciliation

- [ ] 2.1 Add the startup-merge transaction origin and a tested helper that prepends accepted startup text with one LF only when neither nonempty side supplies a supported newline boundary.
- [ ] 2.2 Reconcile successful loads by capturing the startup draft and selection, constructing the coordinator from the stored snapshot, and applying the prefix through the typed transaction path without displaying a stored-only intermediate state.
- [ ] 2.3 Verify the merge preserves the stored document ID, revision ordering, unaffected line metadata, landmarks, invocation state, and exact existing newline bytes across empty and nonempty boundary cases.
- [ ] 2.4 Submit the reconciled revision exactly once to ordinary autosave/history scheduling and verify newer edits remain authoritative if its save completes later.

## 3. Undo, focus, and native input

- [ ] 3.1 Replace transitional undo snapshots at successful reconciliation with one loaded-document startup-merge undo group whose Undo and Redo cannot restore the placeholder identity.
- [ ] 3.2 Preserve and clamp the startup-relative UTF-16 selection, first responder, and viewport through the single merged projection.
- [ ] 3.3 Defer successful reconciliation while marked text is active, then include committed composition text or exclude cancelled composition without forcing a candidate to commit.

## 4. Editable recovery behavior

- [ ] 4.1 Keep the transitional coordinator, text, selection, focus, and undo active when load fails or a future version is refused, and expose the typed recovery-editing phase.
- [ ] 4.2 Prove recovery editing cannot autosave, retain history, retry as an ordinary save, or mutate the failed source while separate recovery-copy export remains possible.
- [ ] 4.3 Preserve terminal ownership-conflict behavior so a duplicate process does not enter recovery editing or touch the store.

## 5. Native regression coverage and verification

- [ ] 5.1 Replace AppKit helpers that await `isEditable` with helpers that await the required typed startup phase.
- [ ] 5.2 Add deterministic native tests for delayed success with and without startup edits, all supported newline boundaries, selection/focus, pre- and post-load undo/redo, IME commit/cancel, load failure, and immediate continued typing.
- [ ] 5.3 Add a relaunch test proving a saved merge returns the startup prefix above the intact stored content with the stored document identity.
- [ ] 5.4 Run relevant document, persistence, AppKit, IME, undo, failure-injection, and UI lifecycle tests and record any separately owned performance limitations.
