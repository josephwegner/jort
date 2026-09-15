import AppKit
import XCTest
import JortDocument
import JortPersistence
@testable import JortAppKit

@MainActor final class StartupEditorTests: StoreTestCase {
  private func shell(_ store: StartupLoadStore) -> (EditorViewController, NSWindow) {
    _ = NSApplication.shared
    let editor = EditorViewController(persistence: PersistenceController(store: store))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = editor
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(editor.textView)
    editor.textView.history.groupsByEvent = false
    XCTAssertEqual(editor.startupPhase, .loading)
    XCTAssertTrue(editor.textView.isEditable)
    return (editor, window)
  }
  private func insert(_ text: String, into editor: EditorViewController) {
    editor.textView.history.beginUndoGrouping()
    editor.textView.insertText(text, replacementRange: editor.textView.selectedRange())
    editor.textView.history.endUndoGrouping()
  }
  private func resolve(
    _ result: Result<DocumentSnapshot, StoreError>, store: StartupLoadStore,
    editor: EditorViewController, phase: EditorStartupPhase
  ) async {
    let resolved = expectation(description: "typed startup phase")
    editor.onStartupPhase = { if $0 == phase { resolved.fulfill() } }
    await store.resolve(result)
    await fulfillment(of: [resolved], timeout: 5)
    editor.onStartupPhase = nil
    XCTAssertEqual(editor.startupPhase, phase)
  }
  private func baseline(_ text: String = "stored\r\ntail") throws -> DocumentSnapshot {
    let owner = try DocumentCoordinator(snapshot: DocumentSnapshot())
    try owner.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .edit(text: text, range: nil, replacementLength: nil)))
    return owner.snapshot
  }
  func testDelayedMergeSelectionUndoContinuedTypingAndRelaunch() async throws {
    let store = StartupLoadStore()
    let (editor, window) = shell(store)
    defer { window.orderOut(nil) }
    let stored = try baseline()
    insert("early😀", into: editor)
    editor.textView.history.undo()
    XCTAssertEqual(editor.state.text, "")
    editor.textView.history.redo()
    XCTAssertEqual(editor.state.text, "early😀")
    let selection = NSRange(location: 2, length: 3)
    editor.textView.setSelectedRange(selection)
    await resolve(.success(stored), store: store, editor: editor, phase: .ready)
    XCTAssertEqual(editor.state.text, "early😀\nstored\r\ntail")
    XCTAssertEqual(editor.state.documentID, stored.documentID)
    XCTAssertEqual(editor.textView.selectedRange(), selection)
    XCTAssertTrue(window.firstResponder === editor.textView)
    editor.textView.history.undo()
    XCTAssertEqual(editor.state.text, stored.text)
    XCTAssertEqual(editor.state.documentID, stored.documentID)
    editor.textView.history.redo()
    XCTAssertEqual(editor.state.text, "early😀\nstored\r\ntail")
    XCTAssertEqual(editor.state.documentID, stored.documentID)
    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    insert("more ", into: editor)
    let flushed = expectation(description: "saved merge")
    editor.persistence.flush {
      XCTAssertTrue($0)
      flushed.fulfill()
    }
    await fulfillment(of: [flushed], timeout: 5)
    let writes = await store.writes
    XCTAssertEqual(writes.count, 1)
    XCTAssertEqual(writes.last, editor.state)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    removeAfterStoresClose(root)
    let disk = ownStore(SQLiteStore(directory: root))
    _ = try await disk.load()
    _ = try await disk.save(editor.state)
    try await disk.close()
    let reopened = ownStore(SQLiteStore(directory: root))
    let recovered = try await reopened.load()
    XCTAssertEqual(recovered, editor.state)
  }
  func testDelayedSuccessWithoutDraftAndNewlineBoundaries() async throws {
    for draft in [
      "", "early", "early\n", "early\r\n", "early\r", "early\u{85}", "early\u{2028}",
      "early\u{2029}",
    ] {
      let store = StartupLoadStore()
      let (editor, window) = shell(store)
      let stored = try baseline()
      if !draft.isEmpty { insert(draft, into: editor) }
      await resolve(.success(stored), store: store, editor: editor, phase: .ready)
      XCTAssertEqual(
        editor.state.text, StartupMerge.prefix(draft: draft, stored: stored.text) + stored.text)
      XCTAssertEqual(editor.state.documentID, stored.documentID)
      if draft.isEmpty {
        XCTAssertEqual(editor.state, stored)
        XCTAssertFalse(editor.textView.history.canUndo)
      }
      window.orderOut(nil)
    }
  }
  func testMarkedTextDefersLoadUntilCommitOrCancellation() async throws {
    for commit in [true, false] {
      let store = StartupLoadStore()
      let (editor, window) = shell(store)
      defer { window.orderOut(nil) }
      insert("early", into: editor)
      editor.textView.setMarkedText(
        "候補", selectedRange: NSRange(location: 2, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0))
      let stored = try baseline()
      await resolve(.success(stored), store: store, editor: editor, phase: .resolvingLoadedSnapshot)
      XCTAssertTrue(editor.textView.hasMarkedText())
      XCTAssertEqual(editor.state.text, "early")
      let ready = expectation(description: "composition resolved")
      editor.onStartupPhase = { if $0 == .ready { ready.fulfill() } }
      editor.textView.history.beginUndoGrouping()
      editor.textView.insertText(
        commit ? "確定" : "", replacementRange: editor.textView.markedRange())
      editor.textView.history.endUndoGrouping()
      await fulfillment(of: [ready], timeout: 5)
      editor.onStartupPhase = nil
      XCTAssertEqual(editor.startupPhase, .ready)
      XCTAssertEqual(editor.state.text, (commit ? "early確定" : "early") + "\n" + stored.text)
      editor.textView.history.undo()
      XCTAssertEqual(editor.state.text, stored.text)
      XCTAssertEqual(editor.state.documentID, stored.documentID)
    }
  }
  func testFailedLoadKeepsEditableDraftAndUndoButNeverWrites() async throws {
    for error: StoreError in [.io("injected"), .unsupportedVersion, .ownership] {
      let store = StartupLoadStore()
      let (editor, window) = shell(store)
      defer { window.orderOut(nil) }
      insert("keep", into: editor)
      let before = editor.state
      let selection = editor.textView.selectedRange()
      let phase: EditorStartupPhase =
        error == .ownership ? .ownershipConflict : .recoveryEditing(error)
      await resolve(.failure(error), store: store, editor: editor, phase: phase)
      XCTAssertEqual(editor.state, before)
      XCTAssertEqual(editor.textView.selectedRange(), selection)
      if error != .ownership {
        XCTAssertTrue(editor.textView.isEditable)
        XCTAssertTrue(window.firstResponder === editor.textView)
        editor.textView.history.undo()
        XCTAssertEqual(editor.state.text, "")
        editor.textView.history.redo()
        XCTAssertEqual(editor.state.text, "keep")
        insert(" editing", into: editor)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        let exported = expectation(description: "recovery copy")
        editor.persistence.saveRecoveryCopy(snapshot: editor.state, to: copy) {
          if case .failure(let error) = $0 { XCTFail("\(error)") }
          exported.fulfill()
        }
        await fulfillment(of: [exported], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
      } else {
        XCTAssertFalse(editor.textView.isEditable)
      }
      editor.persistence.retry()
      let writes = await store.writes
      XCTAssertTrue(writes.isEmpty)
      XCTAssertNil(editor.persistence.history)
    }
  }
}
