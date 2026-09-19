import XCTest
import AppKit
import JortDocument
import JortPersistence
import os
import SQLite3
@testable import JortAppKit

@MainActor final class HistoryWorkspaceTests: StoreTestCase {
  func testWorkspaceConstruction() {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HistoryConstruction-\(UUID())")
    removeAfterStoresClose(root)
    let store = ownStore(SQLiteStore(directory: root))
    let workspace = HistoryWorkspaceController(store: store)
    _ = workspace.view
    workspace.model.cancel()
  }
  private func editor(inject: @escaping @Sendable (StoreStage) throws -> Void = { _ in })
    async throws -> (EditorViewController, NSWindow, any HistoryStore)
  {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HistoryWorkspace-\(UUID())")
    removeAfterStoresClose(root)
    let controller = EditorViewController(
      persistence: ownPersistence(store: ownStore(SQLiteStore(directory: root, inject: inject))))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentViewController = controller
    window.setContentSize(NSSize(width: 920, height: 680))
    window.makeKeyAndOrderFront(nil)
    for _ in 0..<500 {
      if controller.startupPhase == .ready { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(controller.startupPhase, .ready)
    controller.textView.history.groupsByEvent = false
    return (controller, window, try await controller.persistence.openHistory())
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for history")
  }

  func testPreviewModesFooterDismissalAndResize() async throws {
    let (editor, window, store) = try await editor()
    defer { window.orderOut(nil) }
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .native,
        mutation: .edit(
          text: "First thought\nSecond thought\nThird thought", range: nil, replacementLength: nil))
    )
    editor.textView.history.beginUndoGrouping()
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .metadata,
        mutation: .landmark(Landmark(lineID: editor.state.lines[1].id, emoji: "🌲"))))
    editor.textView.history.endUndoGrouping()
    let entry = try await store.retain(
      editor.state, reason: "Landmark changed", timestamp: Date(), milestone: false)
    let before = editor.state, selection = NSRange(location: 3, length: 4)
    editor.textView.setSelectedRange(selection)
    editor.showHistory()
    try await waitUntil { editor.historyWorkspace != nil }
    let workspace = try XCTUnwrap(editor.historyWorkspace)
    try await waitUntil { workspace.model.comparison != nil }
    XCTAssertEqual(workspace.model.selectedSequence, entry.sequence)
    XCTAssertTrue(editor.footer.isHidden)
    XCTAssertFalse(editor.textView.isEditable)
    XCTAssertFalse(workspace.snapshot.isEditable)
    XCTAssertEqual(workspace.snapshot.string, before.text)
    XCTAssertTrue(workspace.status.stringValue.contains("Read-only"))
    XCTAssertEqual(
      (workspace.snapshotScroll.verticalRulerView as? LineRuler)?.landmarks, before.landmarks)
    workspace.mode.selectedSegment = 1
    workspace.selectPresentation()
    XCTAssertFalse(workspace.snapshotScroll.isHidden)
    workspace.mode.selectedSegment = 0
    workspace.selectPresentation()
    XCTAssertFalse(workspace.changesScroll.isHidden)
    XCTAssertEqual(workspace.changes.intercellSpacing, .zero)
    XCTAssertFalse(workspace.restore.superview === editor.footer)
    XCTAssertTrue(workspace.restore.superview === workspace.done.superview)
    let changedCell = try XCTUnwrap(
      workspace.tableView(workspace.changes, viewFor: nil, row: 1) as? HistoryDiffCell)
    changedCell.frame = NSRect(x: 0, y: 0, width: 640, height: 24)
    changedCell.layoutSubtreeIfNeeded()
    XCTAssertLessThan(try XCTUnwrap(changedCell.textField).frame.minX, 130)
    for size in [NSSize(width: 460, height: 300), NSSize(width: 920, height: 680)] {
      window.setContentSize(size)
      editor.view.layoutSubtreeIfNeeded()
      await settlePresentationAsync(editor)
      XCTAssertGreaterThan(workspace.snapshotScroll.frame.width, 100)
      XCTAssertEqual(workspace.view.bounds.size, editor.view.bounds.size)
    }
    let image = try XCTUnwrap(
      workspace.view.bitmapImageRepForCachingDisplay(in: workspace.view.bounds))
    workspace.view.cacheDisplay(in: workspace.view.bounds, to: image)
    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
      to: URL(fileURLWithPath: "/private/tmp/jort-history-workspace.png"))
    workspace.dismissHistory()
    XCTAssertNil(editor.historyWorkspace)
    XCTAssertFalse(editor.footer.isHidden)
    XCTAssertTrue(editor.textView.isEditable)
    XCTAssertEqual(editor.state, before)
    XCTAssertEqual(editor.textView.selectedRange(), selection)
    XCTAssertTrue(window.firstResponder === editor.textView)
  }

  func testRestorePreservesCurrentStateAndUndoRedoAsOneOperation() async throws {
    let (editor, window, store) = try await editor()
    defer { window.orderOut(nil) }
    let original = editor.state
    let entries = try await store.revisions(before: nil, limit: 10)
    let initial = try XCTUnwrap(entries.first)
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .native,
        mutation: .edit(text: "Do not lose this", range: nil, replacementLength: nil)))
    editor.textView.history.beginUndoGrouping()
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .metadata,
        mutation: .landmark(Landmark(lineID: editor.state.lines[0].id, emoji: "🦊"))))
    editor.textView.history.endUndoGrouping()
    let before = editor.state
    editor.textView.setSelectedRange(NSRange(location: 2, length: 3))
    editor.showHistory()
    try await waitUntil { editor.historyWorkspace != nil }
    try await editor.restoreHistory(sequence: initial.sequence)
    XCTAssertEqual(editor.state.text, original.text)
    XCTAssertEqual(editor.state.lines, original.lines)
    XCTAssertGreaterThan(editor.state.revision, before.revision)
    XCTAssertNil(editor.historyWorkspace)
    editor.textView.undo(nil)
    XCTAssertEqual(editor.state.text, before.text)
    XCTAssertEqual(editor.state.lines, before.lines)
    XCTAssertEqual(editor.state.landmarks, before.landmarks)
    XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 3))
    editor.textView.redo(nil)
    XCTAssertEqual(editor.state.text, original.text)
    let retained = try await store.revisions(before: nil, limit: 100)
    var preserved = false
    for entry in retained {
      let revision = try await store.revision(sequence: entry.sequence)
      if revision.snapshot.text == before.text && revision.snapshot.landmarks == before.landmarks {
        preserved = true
      }
    }
    XCTAssertTrue(preserved)
    let saved = await withCheckedContinuation { continuation in
      editor.persistence.flushLifecycle(reason: .windowClosed) {
        continuation.resume(returning: $0)
      }
    }
    XCTAssertTrue(saved)
    let expected = editor.state
    let sqlite = try XCTUnwrap(store as? SQLiteStore)
    let directory = await sqlite.directory
    try await sqlite.close()
    let reopened = ownStore(SQLiteStore(directory: directory))
    let loaded = try await reopened.load()
    XCTAssertEqual(loaded, expected, "Relaunch must recover the complete restored state")
    try await reopened.close()
  }

  func testNoBaselineAndSupersededSelection() async throws {
    let (editor, window, store) = try await editor()
    defer { window.orderOut(nil) }
    let model = HistoryBrowserModel(store: store)
    model.loadMore()
    try await waitUntil { model.selected != nil && !model.message.contains("Looking") }
    XCTAssertNil(model.comparison)
    let first = try XCTUnwrap(model.selectedSequence)
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .native,
        mutation: .edit(text: "Newer", range: nil, replacementLength: nil)))
    let newest = try await store.retain(
      editor.state, reason: "Newer", timestamp: Date(), milestone: false)
    model.select(first)
    model.select(newest.sequence)
    model.select(first)
    try await waitUntil {
      model.selected != nil && !model.loading && !model.message.contains("Looking")
    }
    XCTAssertEqual(model.selectedSequence, first)
    XCTAssertEqual(model.selected?.snapshot.text, "")
    XCTAssertNil(model.comparison)
    model.cancel()
  }

  func testFailedPreservationRefusesRestore() async throws {
    let failing = OSAllocatedUnfairLock(initialState: false)
    let (editor, window, store) = try await editor { stage in
      if stage == .historyCommit, failing.withLock({ $0 }) {
        throw StoreError.sqlite(13, "disk full")
      }
    }
    defer { window.orderOut(nil) }
    let entries = try await store.revisions(before: nil, limit: 1)
    let sequence = try XCTUnwrap(entries.first).sequence
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .native,
        mutation: .edit(text: "Must survive", range: nil, replacementLength: nil)))
    let before = editor.state
    editor.showHistory()
    try await waitUntil { editor.historyWorkspace != nil }
    failing.withLock { $0 = true }
    do {
      try await editor.restoreHistory(sequence: sequence)
      XCTFail("Must refuse restore")
    } catch {}
    XCTAssertEqual(editor.state, before)
    XCTAssertNotNil(editor.historyWorkspace)
    failing.withLock { $0 = false }
    editor.dismissHistory()
  }

  func testLiveMutationDuringPreservationRefusesStaleRestore() async throws {
    let (editor, window, store) = try await editor()
    defer { window.orderOut(nil) }
    let entries = try await store.revisions(before: nil, limit: 1)
    let sequence = try XCTUnwrap(entries.first).sequence
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .native,
        mutation: .edit(text: "Before", range: nil, replacementLength: nil)))
    editor.showHistory()
    try await waitUntil { editor.historyWorkspace != nil }
    var changed = false
    editor.persistence.onHistoryState = {
      guard !changed else { return }
      changed = true
      _ = try? editor.apply(
        .init(
          baseRevision: editor.state.revision, origin: .native,
          mutation: .edit(text: "Arrived during restore", range: nil, replacementLength: nil)))
    }
    do {
      try await editor.restoreHistory(sequence: sequence)
      XCTFail("Must refuse stale restore")
    } catch {}
    XCTAssertTrue(changed)
    XCTAssertEqual(editor.state.text, "Arrived during restore")
    editor.persistence.onHistoryState = nil
    editor.dismissHistory()
  }

  func testCorruptRevisionDisablesPreviewAndRestore() async throws {
    let (editor, window, store) = try await editor()
    defer { window.orderOut(nil) }
    let sqlite = try XCTUnwrap(store as? SQLiteStore)
    let directory = await sqlite.directory
    var db: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open(directory.appendingPathComponent("Store/Jort.sqlite").path, &db), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(db, "UPDATE history_revisions SET payload=X'00'", nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    let before = editor.state
    editor.showHistory()
    try await waitUntil { editor.historyWorkspace != nil }
    let workspace = try XCTUnwrap(editor.historyWorkspace)
    try await waitUntil { !workspace.model.unavailable.isEmpty }
    XCTAssertNil(workspace.model.selected)
    XCTAssertFalse(workspace.restore.isEnabled)
    XCTAssertEqual(workspace.snapshot.string, "")
    XCTAssertEqual(editor.state, before)
    editor.dismissHistory()
  }

  func testConfirmationCancelAndKeyboardExpansion() async throws {
    let (editor, window, store) = try await editor()
    defer { window.orderOut(nil) }
    let originalText = (0..<30).map { "Line \($0)" }.joined(separator: "\n")
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .native,
        mutation: .edit(text: originalText, range: nil, replacementLength: nil)))
    _ = try await store.retain(editor.state, reason: "Earlier", timestamp: Date(), milestone: false)
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .native,
        mutation: .edit(text: originalText + "\nNew line", range: nil, replacementLength: nil)))
    _ = try await store.retain(editor.state, reason: "Latest", timestamp: Date(), milestone: false)
    let before = editor.state
    editor.showHistory()
    try await waitUntil { editor.historyWorkspace?.model.comparison != nil }
    let workspace = try XCTUnwrap(editor.historyWorkspace)
    let count = workspace.changes.numberOfRows
    let collapsed = (0..<count).first { index in
      let cell = workspace.tableView(workspace.changes, viewFor: nil, row: index)
      return cell?.subviews.contains {
        ($0 as? NSButton)?.title.contains("unchanged lines") == true
      } == true
    }
    let row = try XCTUnwrap(collapsed)
    let foldCell = try XCTUnwrap(workspace.tableView(workspace.changes, viewFor: nil, row: row))
    try XCTUnwrap(foldCell.subviews.first as? NSButton).performClick(nil)
    XCTAssertGreaterThan(workspace.changes.numberOfRows, count)
    workspace.restore.performClick(nil)
    try await waitUntil { window.attachedSheet != nil }
    window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(editor.state, before)
    XCTAssertNotNil(editor.historyWorkspace)
    XCTAssertTrue(workspace.restore.isEnabled)
    editor.dismissHistory()
  }

  func testTypingThenLandmarkPreservesAndRetainsBoth() async throws {
    let (editor, window, store) = try await editor()
    defer { window.orderOut(nil) }
    editor.textView.history.beginUndoGrouping()
    editor.textView.insertText("Original\n", replacementRange: NSRange(location: 0, length: 0))
    editor.textView.history.endUndoGrouping()
    XCTAssertEqual(editor.state.text, "Original\n")
    // Simulate text committed by the native editor before its notification arrives.
    editor.textView.string = "Original\nJust typed 🦊"
    editor.mutateLandmark(.landmark(Landmark(lineID: editor.state.lines[0].id, emoji: "🌲")))
    XCTAssertEqual(editor.textView.string, "Original\nJust typed 🦊")
    XCTAssertEqual(editor.state.text, editor.textView.string)
    XCTAssertEqual(editor.state.landmarks.count, 1)
    let saved = await withCheckedContinuation { continuation in
      editor.persistence.flushLifecycle(reason: .deactivation) {
        continuation.resume(returning: $0)
      }
    }
    XCTAssertTrue(saved)
    let entries = try await store.revisions(before: nil, limit: 1)
    let revision = try await store.revision(sequence: XCTUnwrap(entries.first).sequence)
    XCTAssertEqual(revision.snapshot.text, editor.state.text)
    XCTAssertEqual(revision.snapshot.landmarks, editor.state.landmarks)
  }

  func testNewLinesKeepEveryVisibleOrdinalWithoutScrollingOrLandmarks() async throws {
    let (editor, window, _) = try await editor()
    defer { window.orderOut(nil) }
    for index in 0..<18 {
      editor.textView.history.beginUndoGrouping()
      editor.textView.insertText(
        "Line \(index)\n",
        replacementRange: NSRange(location: editor.textView.string.utf16.count, length: 0))
      editor.textView.history.endUndoGrouping()
      try await Task.sleep(for: .milliseconds(10))
      editor.view.layoutSubtreeIfNeeded()
      await settlePresentationAsync(editor)
      XCTAssertEqual(editor.state.text, editor.textView.string)
      let ruler = try XCTUnwrap(editor.scroll.verticalRulerView as? LineRuler)
      XCTAssertEqual(ruler.visibleRows().map(\.number), Array(1...(index + 2)))
    }
  }

  func testHistoryLoadsAnotherPageOnScrollAndVisibleRowCounts() async throws {
    let (editor, window, store) = try await editor()
    defer { window.orderOut(nil) }
    let owner = try DocumentCoordinator(snapshot: editor.state)
    for index in 0..<104 {
      try owner.apply(
        .init(
          baseRevision: owner.snapshot.revision, origin: .native,
          mutation: .edit(text: "Revision \(index)", range: nil, replacementLength: nil)))
      _ = try await store.retain(
        owner.snapshot, reason: "Typing paused", timestamp: Date(), milestone: false)
    }
    editor.showHistory()
    try await waitUntil { editor.historyWorkspace?.model.entries.count == 100 }
    let workspace = try XCTUnwrap(editor.historyWorkspace)
    try await waitUntil { workspace.model.summaries[workspace.model.entries[0].sequence] != nil }
    if case .changes(let added, let removed) = workspace.model.summaries[
      workspace.model.entries[0].sequence]
    {
      XCTAssertEqual(added, 1)
      XCTAssertEqual(removed, 1)
    } else {
      XCTFail("Expected inline change counts")
    }
    workspace.view.layoutSubtreeIfNeeded()
    workspace.revisions.scrollRowToVisible(99)
    try await waitUntil { workspace.model.entries.count == 105 }
    XCTAssertFalse(workspace.model.hasMore)
    editor.dismissHistory()
  }
}
