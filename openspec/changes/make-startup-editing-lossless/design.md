## Context

`EditorViewController` currently constructs an empty `DocumentCoordinator`, marks the editor ready, and makes the text view editable before calling `PersistenceController.load`. Native edits therefore apply to the placeholder coordinator. Although `PersistenceController.changed` does not schedule a save until its private `ready` flag is true, it assigns the submitted placeholder snapshot to `pending` before that guard. More importantly, the load callback compares the live snapshot with the original placeholder and, if they differ, submits the placeholder-derived document after load rather than merging it with the loaded snapshot.

The current test helper waits for `textView.isEditable`, which is true before the asynchronous load begins. Tests that use the helper can therefore exercise startup state while believing the document is loaded.

Disabling the editor until load finishes would close the overwrite race but violate the product requirement that Jort feel immediately available for text. The design instead treats pre-load editing as a short-lived draft that is reconciled with the authoritative stored snapshot once load resolves.

## Goals / Non-Goals

**Goals:**

- Accept native text input and focus the editor as soon as the AppKit shell is ready.
- Prevent any placeholder-derived document identity or snapshot from becoming authoritative before load resolution.
- Preserve the stored document identity and existing metadata when startup text is prepended.
- Preserve the user's startup text, selection, native input behavior, and a safe undo path.
- Keep editing available after load failure without allowing that recovery state to overwrite the failed source.
- Expose deterministic lifecycle state for tests and UI coordination.

**Non-Goals:**

- Making startup read-only.
- Changing the persistence schema or document payload format.
- Solving steady-state transaction performance or snapshot structural sharing.
- Adding recovery-copy import or replacing the failed source store.
- Preserving every individual pre-load native undo group after reconciliation; startup input becomes one safe merge group.

## Decisions

### Add an explicit editor startup phase

Replace the overloaded `ready` Boolean and snapshot-equality check with a typed editor-owned phase similar to:

```swift
enum EditorStartupPhase: Equatable {
    case loading
    case resolvingLoadedSnapshot
    case ready
    case recoveryEditing(StoreError)
}
```

The exact visibility of the type may remain internal, but tests receive a deterministic observation/wait hook. `isEditable` describes native UI capability only and is never used as a load-completion signal.

Persistence retains its existing typed `PersistenceState`; editor startup phase composes persistence resolution with AppKit input state rather than pretending recovery editing is a healthy writable store.

### Use the initial coordinator as a transitional startup draft

The initial coordinator remains the sole mutable owner of accepted canonical startup text while the load is pending. It is explicitly a transitional draft and is never submitted to persistence. Native text, Unicode/newline handling, IME commit rules, and pre-load undo/redo continue to use the normal text adapter and coordinator behavior.

On load success, the controller captures the draft's final accepted text and selection, discards undo snapshots tied to the draft document identity, creates the authoritative coordinator from the loaded snapshot, installs its transaction observer, and applies one startup-prefix transaction if the draft is nonempty.

An independent string buffer was considered but rejected because it would duplicate native edit, IME, and undo semantics. Reusing the transitional coordinator preserves one mutation path while the explicit phase and persistence gate prevent it from becoming a second long-lived document owner.

### Prepend through a distinct typed transaction

Add a `startup` or `startupMerge` mutation origin and apply a normal edit at UTF-16 offset zero against the loaded coordinator. The transaction's before snapshot is the exact loaded snapshot and its after snapshot retains the loaded document ID. Existing insertion reconciliation preserves unaffected stored line IDs when the prefix creates complete lines; boundary-line metadata follows the normative line-identity rules when startup text fills an existing leading empty line.

The merged text is:

```text
startup text + optional LF boundary + stored text
```

Insert one `\n` boundary only when both texts are nonempty, startup text does not end in any supported newline sequence, and stored text does not begin with any supported newline sequence. Existing bytes and newline sequences are otherwise unchanged. The inserted LF matches the native Return convention and is generated only because the user requested two distinct top/document regions without supplying their own boundary.

Directly constructing a replacement `DocumentSnapshot` was rejected because it could bypass transaction revision, line identity, invocation remapping, undo, and persistence observers.

### Collapse reconciliation into one safe undo group

Undo history created against the transitional draft contains snapshots with a different document ID and cannot survive coordinator replacement safely. At successful load resolution, clear that history and register the prefix transaction's loaded before-snapshot as one undo group. Undo removes all startup content and the generated boundary while leaving the loaded document intact; Redo restores the same merged result.

Before load resolves, existing native undo/redo continues to operate on the startup draft. This intentionally trades fine-grained post-load startup undo for a simple invariant: no undo action can restore a placeholder snapshot over the loaded document.

### Preserve focus and startup selection

Because startup text remains at offset zero in the merged document, a selection wholly within accepted startup text keeps the same UTF-16 range. Clamp the range to the startup prefix if native state is temporarily inconsistent, apply the merged display atomically, restore the selection, and leave the text view first responder unless a transient native control intentionally owns focus.

The loaded document must not flash alone between the draft and merged display. With no startup content, install and display the loaded snapshot normally.

### Defer successful reconciliation during marked-text composition

Provisional marked text is native display state, not canonical startup content. If load succeeds while the text view has marked text, retain the loaded result without changing the displayed text or committing the candidate. Complete reconciliation after the composition commits or is cancelled. A commit first enters the startup coordinator and is then included in the prefix; cancellation leaves it out.

Forcing `unmarkText` at load completion was rejected because it could commit a candidate the user had not accepted. Replacing text storage immediately was rejected because it can disrupt the input method and lose provisional input.

### Fail closed at the persistence boundary

Move the `ready` guard in `PersistenceController.changed` ahead of any assignment to `pending`, history initialization, state transition, or scheduling. A snapshot received while persistence is loading or load-blocked is ignored and cannot displace the store-loaded pending snapshot.

The editor also refrains from calling `changed` for transitional startup transactions. Defense at both layers prevents a future callback refactor from reintroducing the overwrite path.

After a successful load and merge, the merged snapshot is submitted once through ordinary persistence/history scheduling. The loaded snapshot remains the committed baseline until that save succeeds.

### Keep load failure as editable, non-writing recovery state

When load fails or a future version is refused, keep the transitional coordinator and current startup content as the live in-memory document. Move the editor phase to `recoveryEditing(error)`, preserve focus and undo, and expose the existing storage attention UI. Persistence remains not ready, so autosave, retry-as-save, history, and ordinary store writes cannot target the failed source. Explicit recovery-copy export may serialize the current in-memory snapshot to a user-selected separate location.

Ownership conflict remains terminal for the duplicate process and does not become recovery editing.

## Risks / Trade-offs

- **Risk: Load resolves in the middle of IME composition.** → Hold the successful result and reconcile only after native composition commits or cancels; test both paths.
- **Risk: Old undo snapshots restore the placeholder identity.** → Clear transitional history and register exactly one loaded-document prefix undo group.
- **Risk: A generic prefix edit changes metadata on the stored first line.** → Exercise leading empty/nonempty lines and newline combinations against the normative line-identity rules; introduce a domain prepend mutation only if the generic edit cannot preserve those rules.
- **Risk: Startup merge briefly displays stored-only content or loses selection.** → Construct/apply the authoritative transaction before the single text-view projection and restore the startup-relative range.
- **Risk: A later persistence refactor accepts pre-load snapshots again.** → Enforce the ready gate before mutating persistence internals and add a storage-level delayed-load test independent of AppKit.
- **Trade-off: Post-load Undo removes startup input as one group.** → Prefer a safe, comprehensible boundary over replaying foreign-document undo snapshots; document and test the behavior.

## Migration Plan

1. Add the typed editor startup phase and deterministic test observation hook while preserving current behavior.
2. Gate `PersistenceController.changed` before all pre-load mutation and add storage-level regression tests.
3. Add the startup transaction origin and merge helper with complete newline-boundary tests.
4. Reconcile successful loads through the loaded coordinator, one undo group, selection restoration, and one persistence submission.
5. Add marked-text deferral and editable recovery-state behavior.
6. Replace all tests that use `isEditable` as load completion with the typed phase.
7. Run headless persistence tests, native editor/IME/undo tests, delayed-load tests, and relaunch verification.

No on-disk migration is needed. Rollback is a source change, but reverting would restore a known document-overwrite race and is not an acceptable release state.

## Open Questions

- Confirm during implementation whether generic line reconciliation preserves every stored line identity for all boundary cases. If not, add a narrowly defined domain-level prepend mutation rather than weakening identity requirements.
- Confirm whether the current test store protocol needs a controllable continuation-based load fixture or whether an existing injected store can expose deterministic delayed success and failure.
