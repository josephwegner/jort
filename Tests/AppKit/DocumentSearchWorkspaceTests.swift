import XCTest
import AppKit
import JortDocument
import JortPersistence
@testable import JortAppKit

@MainActor final class DocumentSearchWorkspaceTests: StoreTestCase {
  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for search")
  }
  private func editor() async throws -> (EditorViewController, NSWindow) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SearchWorkspace-\(UUID())")
    removeAfterStoresClose(root)
    let editor = EditorViewController(
      persistence: ownPersistence(store: ownStore(SQLiteStore(directory: root))))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentViewController = editor
    window.setContentSize(NSSize(width: 920, height: 680))
    window.makeKeyAndOrderFront(nil)
    try await waitUntil { editor.startupPhase == .ready }
    return (editor, window)
  }
  func testLazyPaletteSearchKeyboardNavigationAndWrappedMatch() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    XCTAssertNil(editor.documentSearch)
    XCTAssertTrue(editor.paletteActions().contains { $0.id == "search.document" })
    let text = String(repeating: "wrapped text ", count: 100) + "👩🏽‍💻 needle\nsecond needle"
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .native,
        mutation: .edit(text: text, range: nil, replacementLength: nil)))
    let before = editor.state
    editor.view.layoutSubtreeIfNeeded()
    let windowSize = window.frame.size
    editor.showDocumentSearch()
    let search = try XCTUnwrap(editor.documentSearch)
    editor.view.layoutSubtreeIfNeeded()
    let collapsedHeight = search.view.frame.height
    XCTAssertTrue(search.view.superview === editor.view)
    XCTAssertTrue(search.window === window)
    XCTAssertEqual(search.query.accessibilityLabel(), "Document search query")
    search.query.stringValue = "needle"
    search.refreshQuery()
    try await waitUntil { search.model.results.count == 2 }
    editor.view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(search.view.frame.height, collapsedHeight)
    XCTAssertEqual(window.frame.size, windowSize)
    XCTAssertTrue(editor.view.bounds.contains(search.view.frame))
    XCTAssertTrue(
      search.model.results.allSatisfy { !$0.snippet.contains("↵") && !$0.snippet.contains("\n") })
    XCTAssertFalse(search.model.results[0].snippet.contains("second needle"))
    let content = try XCTUnwrap(search.window?.contentView)
    content.layoutSubtreeIfNeeded()
    let image = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: image)
    try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
      to: URL(fileURLWithPath: "/private/tmp/jort-document-search.png"))
    XCTAssertTrue(
      search.control(
        search.query, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
    let match = search.model.results[1]
    XCTAssertTrue(
      search.control(
        search.query, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    )
    XCTAssertNotNil(editor.documentSearch)
    XCTAssertEqual(editor.textView.selectedRange(), match.resolve(in: before))
    XCTAssertEqual(editor.state, before)
    XCTAssertTrue(window.firstResponder === editor.textView)
    search.previousMatch()
    XCTAssertEqual(editor.textView.selectedRange(), search.model.results[0].resolve(in: before))
    search.nextMatch()
    XCTAssertEqual(editor.textView.selectedRange(), match.resolve(in: before))
    editor.textView.cancelOperation(nil)
    XCTAssertNil(editor.documentSearch)
  }
  func testStaleSelectionRefreshesWithoutNavigating() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .native,
        mutation: .edit(text: "needle", range: nil, replacementLength: nil)))
    editor.showDocumentSearch()
    let search = try XCTUnwrap(editor.documentSearch)
    search.query.stringValue = "needle"
    search.refreshQuery()
    try await waitUntil { search.model.results.count == 1 }
    try editor.apply(
      .init(
        baseRevision: editor.state.revision, origin: .native,
        mutation: .edit(text: "changed", range: nil, replacementLength: nil)))
    editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
    search.activateSelection()
    XCTAssertNotNil(editor.documentSearch)
    XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 0))
    try await waitUntil { search.model.message == "No matches" }
    search.dismiss()
  }
  func testSupersededQueriesOptionsAndCancellation() async throws {
    let owner = try DocumentCoordinator()
    try owner.apply(
      .init(
        baseRevision: 0, origin: .native,
        mutation: .edit(text: "cat Cat scatter dog", range: nil, replacementLength: nil)))
    let model = DocumentSearchModel()
    model.search(snapshot: owner.snapshot, query: "dog", options: .init())
    model.search(
      snapshot: owner.snapshot, query: "cat", options: .init(caseSensitive: true, wholeWord: true))
    try await waitUntil { model.message == "1 match" }
    XCTAssertEqual(model.results[0].lineRange, NSRange(location: 0, length: 3))
    model.search(snapshot: owner.snapshot, query: "dog", options: .init())
    model.search(snapshot: owner.snapshot, query: "", options: .init())
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(model.results.isEmpty)
    XCTAssertEqual(model.message, "Enter text to search this document")
    model.cancel()
  }
  func testDismissalAndIMECompositionDoNotExecuteSearchResult() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
    editor.showDocumentSearch()
    let search = try XCTUnwrap(editor.documentSearch)
    let composing = NSTextView()
    composing.setMarkedText(
      "に", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertFalse(
      search.control(
        search.query, textView: composing, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertNotNil(editor.documentSearch)
    search.dismiss()
    XCTAssertNil(editor.documentSearch)
    XCTAssertTrue(window.firstResponder === editor.textView)
    XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 0, length: 0))
  }
}
