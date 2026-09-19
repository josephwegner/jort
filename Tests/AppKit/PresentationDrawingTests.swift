import AppKit
import XCTest
@testable import JortAppKit

/// Captures mutations, including edits that are reverted before draw returns.
@MainActor private final class PaintProbe: NSObject {
  struct ViewState: Equatable {
    let identity: ObjectIdentifier
    let frame: NSRect
    let hidden: Bool
    let children: [ObjectIdentifier]
  }
  private(set) var storageEdits = 0
  override init() { super.init() }
  func observe(_ storage: NSTextStorage) {
    NotificationCenter.default.addObserver(
      self, selector: #selector(edited),
      name: NSTextStorage.didProcessEditingNotification, object: storage)
  }
  @objc private func edited() { storageEdits += 1 }
  deinit { NotificationCenter.default.removeObserver(self) }
  func hierarchy(_ view: NSView) -> [ViewState] {
    [
      ViewState(
        identity: ObjectIdentifier(view), frame: view.frame, hidden: view.isHidden,
        children: view.subviews.map(ObjectIdentifier.init))
    ] + view.subviews.flatMap(hierarchy)
  }
}

@MainActor final class PresentationDrawingTests: ToolInvocationTestCase {
  func testDrawCharacterization() async throws {
    let (editor, window) = try await editor()
    defer { window.orderOut(nil) }
    let tool = package("paint", output: "result")
    editor.toolPackages = [tool]
    editor.textView.insertText("/paint", replacementRange: NSRange(location: 0, length: 0))
    try editor.toolController.accept(tool, token: NSRange(location: 0, length: 6), space: false)
    editor.view.layoutSubtreeIfNeeded()
    await settlePresentationAsync(editor)
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.refreshToolPresentation()
    await settlePresentationAsync(editor)
    let probe = PaintProbe()
    probe.observe(try XCTUnwrap(editor.textView.textStorage))
    editor.presentationCoordinator.invalidate(.viewport)
    editor.toolPresentation.invalidateStyles()
    let scheduler = editor.presentationCoordinator.state
    let layoutRequests = editor.linePresentation.layoutRequests
    let hierarchy = probe.hierarchy(editor.view)
    let document = editor.state
    let selection = editor.textView.selectedRange()
    let responder = window.firstResponder
    let image = NSImage(size: NSSize(width: 800, height: 600))
    image.lockFocus()
    defer { image.unlockFocus() }
    editor.scroll.verticalRulerView?.drawHashMarksAndLabels(
      in: editor.scroll.verticalRulerView!.bounds)
    editor.toolPresentation.draw(editor.textView.visibleRect)
    editor.footer.draw(editor.footer.bounds)
    editor.footer.landmarks.draw(editor.footer.landmarks.bounds)
    for view in [
      ToolCompletionPopover(frame: NSRect(x: 0, y: 0, width: 200, height: 80)),
      ToolCompletionRow(command: "/paint", name: "Paint", selected: true, action: {}),
      ToolScopeHandle(frame: NSRect(x: 0, y: 0, width: 16, height: 30)),
      ToolActionButton(symbol: "play.fill", label: "Run", action: {}),
    ] as [NSView] {
      let before = probe.hierarchy(view)
      view.draw(view.bounds)
      XCTAssertEqual(probe.hierarchy(view), before)
    }
    XCTAssertEqual(editor.presentationCoordinator.state, scheduler)
    XCTAssertEqual(editor.linePresentation.layoutRequests, layoutRequests)
    XCTAssertEqual(probe.storageEdits, 0)
    XCTAssertEqual(probe.hierarchy(editor.view), hierarchy)
    XCTAssertEqual(editor.state, document)
    XCTAssertEqual(editor.textView.selectedRange(), selection)
    XCTAssertTrue(window.firstResponder === responder)
  }
}

/// Separates framework warnings from mutations in Jort's custom paint paths.
@MainActor final class NativeDrawingBaselineTests: XCTestCase {
  func testSystemWindowAnimationTeardown() async throws {
    _ = NSApplication.shared
    func cycle() async throws {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.animationBehavior = .none
      let controller = NSViewController()
      controller.view = NSTextView(usingTextLayoutManager: true)
      window.contentViewController = controller
      window.makeKeyAndOrderFront(nil)
      try await Task.sleep(for: .milliseconds(80))
      window.orderOut(nil)
      window.close()
      window.contentViewController = nil
    }
    for _ in 0..<5 {
      try await cycle()
      try await Task.sleep(for: .milliseconds(150))
    }
    try await Task.sleep(for: .milliseconds(500))
  }

  func testSystemTextKitWindowWithoutCustomViews() async throws {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    defer { window.orderOut(nil) }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let text = NSTextView(usingTextLayoutManager: true)
    text.frame = scroll.bounds
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    window.contentView = scroll
    window.makeKeyAndOrderFront(nil)
    text.insertText("ordinary system text", replacementRange: NSRange(location: 0, length: 0))
    try await Task.sleep(for: .milliseconds(100))
    window.setContentSize(NSSize(width: 500, height: 350))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(text.string, "ordinary system text")
    text.isVerticallyResizable = true
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.insertText(
      String(repeating: "ordinary system paragraph\n", count: 100),
      replacementRange: NSRange(location: 0, length: text.string.utf16.count))
    for index in 0..<10 {
      text.insertText("x", replacementRange: NSRange(location: index * 20, length: 0))
      text.scrollRangeToVisible(NSRange(location: index * 100, length: 0))
      window.setContentSize(NSSize(width: index.isMultiple(of: 2) ? 500 : 600, height: 350))
      text.textLayoutManager?.textViewportLayoutController.layoutViewport()
      try await Task.sleep(for: .milliseconds(30))
      let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
      scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
    }
    window.close()
  }
}
