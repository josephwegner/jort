import XCTest
import AppKit
import Darwin
import JortDocument
import JortPersistence
@testable import JortAppKit

@MainActor final class EditorWorkspaceTests: EditorTestCase {
  func testShellAndMomentaryLandmarksPreserveEditorState() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert("one\ntwo", range: NSRange(location: 0, length: 0), into: controller)
    let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
    let before = controller.state, selection = controller.textView.selectedRange()
    for size in [NSSize(width: 460, height: 300), NSSize(width: 920, height: 680)] {
      window.setContentSize(size)
      controller.view.layoutSubtreeIfNeeded()
      settlePresentation(controller)
      XCTAssertEqual(controller.footer.frame.height, EditorMetrics.footerHeight)
      XCTAssertEqual(controller.scroll.frame.minY, controller.footer.frame.maxY, accuracy: 0.5)
      XCTAssertEqual(ruler.ruleThickness, 48)
    }
    ruler.optionHeld = true
    XCTAssertTrue(ruler.landmarkMode)
    controller.toggleLandmarkMode()
    ruler.optionHeld = false
    XCTAssertTrue(ruler.landmarkMode)
    controller.toggleLandmarkMode()
    XCTAssertFalse(ruler.landmarkMode)
    XCTAssertEqual(controller.state, before)
    XCTAssertEqual(controller.textView.selectedRange(), selection)
    XCTAssertTrue(window.firstResponder === controller.textView)
    XCTAssertEqual(controller.footer.landmarks.title, "⌥ Landmarks: 0")
  }
  func testHeldOptionInputLifecycleAndAccessibility() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
    controller.viewDidAppear()
    XCTAssertNotNil(controller.modifierMonitor)
    ruler.optionHeld = true
    ruler.optionHeld = true
    XCTAssertTrue(ruler.landmarkMode)
    insert("café first second", range: NSRange(location: 0, length: 0), into: controller)
    controller.textView.moveWordBackward(nil)
    XCTAssertLessThan(
      controller.textView.selectedRange().location, controller.state.text.utf16.count)
    controller.textView.history.beginUndoGrouping()
    controller.textView.setMarkedText(
      "日本", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: controller.textView.selectedRange())
    let beforeCommit = controller.state
    XCTAssertFalse(beforeCommit.text.contains("日本"))
    controller.textView.unmarkText()
    controller.textView.history.endUndoGrouping()
    XCTAssertTrue(controller.state.text.contains("日本"))
    XCTAssertTrue(ruler.landmarkMode)
    controller.textView.undo(nil)
    XCTAssertEqual(controller.state.text, beforeCommit.text)
    NotificationCenter.default.post(
      name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
    XCTAssertFalse(ruler.optionHeld)
    ruler.modeState.latched = true
    ruler.optionHeld = true
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    XCTAssertFalse(ruler.optionHeld)
    XCTAssertTrue(ruler.landmarkMode)
    XCTAssertEqual(controller.footer.landmarks.accessibilityLabel(), "Landmarks")
    XCTAssertTrue(
      (controller.footer.landmarks.accessibilityValue() as? String ?? "").contains("latched"))
    controller.viewDidDisappear()
    XCTAssertNil(controller.modifierMonitor)
  }
  func testShellRenderedStates() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    window.appearance = NSAppearance(named: .darkAqua)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "jort-shell-snapshots")
    removeAfterStoresClose(directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func capture(_ name: String) throws {
      controller.view.layoutSubtreeIfNeeded()
      settlePresentation(controller)
      controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
      let image = try XCTUnwrap(
        controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
      controller.view.cacheDisplay(in: controller.view.bounds, to: image)
      try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
        to: directory.appendingPathComponent("\(name).png"))
      let attachment = XCTAttachment(
        image: NSImage(cgImage: try XCTUnwrap(image.cgImage), size: controller.view.bounds.size))
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    try capture("empty")
    insert(
      "First thought\nSecond thought\nThird thought", range: NSRange(location: 0, length: 0),
      into: controller)
    controller.mutateLandmark(.landmark(Landmark(lineID: controller.state.lines[1].id, emoji: "🌲")))
    try capture("landmarks")
    let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
    ruler.optionHeld = true
    try capture("option-held")
    ruler.optionHeld = false
    controller.present(.loadFailed(.injected("snapshot")))
    try capture("storage-attention")
    window.setContentSize(NSSize(width: 460, height: 300))
    try capture("small")
    XCTAssertFalse(controller.notice.isHidden)
    XCTAssertLessThanOrEqual(controller.notice.frame.maxY, controller.footer.bounds.maxY)
    let footerBitmap = try XCTUnwrap(
      controller.footer.bitmapImageRepForCachingDisplay(in: controller.footer.bounds))
    controller.footer.cacheDisplay(in: controller.footer.bounds, to: footerBitmap)
    let scale = CGFloat(footerBitmap.pixelsWide) / controller.footer.bounds.width
    let sampleX = footerBitmap.pixelsWide - Int(20 * scale)
    let divider = try XCTUnwrap(
      footerBitmap.colorAt(x: sampleX, y: footerBitmap.pixelsHigh - 1)?.usingColorSpace(.deviceRGB))
    let background = try XCTUnwrap(
      footerBitmap.colorAt(x: sampleX, y: footerBitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    XCTAssertNotEqual(divider.redComponent, background.redComponent, accuracy: 0.01)
    window.setContentSize(NSSize(width: 920, height: 680))
    let view = NSTextField(labelWithString: "A test-only explanation anchored to line 2")
    controller.linePresentation.setAccessories([
      LineAccessory(lineID: controller.state.lines[1].id, height: 64, view: view)
    ])
    try capture("expanded")
  }
  func testPaletteFilteringDisabledExecutionAndFocusRestoration() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert("hello\nworld", range: NSRange(location: 0, length: 0), into: controller)
    controller.textView.setSelectedRange(NSRange(location: 1, length: 3))
    let selection = controller.textView.selectedRange(),
      viewport = controller.scroll.contentView.bounds.origin
    let before = controller.state
    controller.showCommandPalette()
    let palette = try XCTUnwrap(controller.palette)
    XCTAssertEqual(palette.window?.accessibilitySubrole(), .dialog)
    XCTAssertEqual(palette.window?.title, "Pocket")
    XCTAssertEqual(palette.window?.accessibilityLabel(), "Pocket")
    palette.query.stringValue = "CLEAR"
    palette.reload()
    XCTAssertEqual(palette.results.count, 1)
    XCTAssertFalse(palette.results[0].enabled())
    palette.executeSelection()
    XCTAssertNotNil(controller.palette)
    palette.query.stringValue = "nothingmatches"
    palette.reload()
    XCTAssertTrue(palette.results.isEmpty)
    XCTAssertEqual(palette.count.stringValue, "No matching actions")
    palette.executeSelection()
    XCTAssertEqual(controller.state, before)
    palette.dismiss()
    XCTAssertNil(controller.palette)
    XCTAssertEqual(controller.textView.selectedRange(), selection)
    XCTAssertEqual(controller.scroll.contentView.bounds.origin, viewport)
    XCTAssertTrue(window.firstResponder === controller.textView)
    let action = PaletteAction(id: "test", title: "Réparer", keywords: "detached", execute: {})
    XCTAssertTrue(action.matches("REPARER"))
    XCTAssertTrue(action.matches("repair") == false)
    XCTAssertTrue(action.matches("DETACHED"))
    controller.mutateLandmark(.landmark(Landmark(lineID: controller.state.lines[0].id, emoji: "🌲")))
    controller.showCommandPalette()
    let changing = try XCTUnwrap(controller.palette)
    changing.query.stringValue = "Clear"
    changing.reload()
    XCTAssertTrue(changing.results[0].enabled())
    controller.clearCurrentLandmark()
    XCTAssertFalse(changing.results[0].enabled())
    let revision = controller.state.revision
    changing.executeSelection()
    XCTAssertEqual(controller.state.revision, revision)
    changing.dismiss()
  }
  func testPaletteExecutionAndIMEGuard() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    let before = controller.state
    controller.textView.history.beginUndoGrouping()
    controller.textView.setMarkedText(
      "に", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 0, length: 0))
    controller.showCommandPalette()
    XCTAssertNil(controller.palette)
    XCTAssertTrue(controller.textView.hasMarkedText())
    XCTAssertEqual(controller.state, before)
    controller.textView.unmarkText()
    controller.textView.history.endUndoGrouping()
    let committed = controller.state
    controller.showCommandPalette()
    let palette = try XCTUnwrap(controller.palette)
    XCTAssertFalse(
      palette.actions.contains {
        $0.id == "landmark.toggle" || $0.id == "app.save" || $0.id == "app.recovery"
      })
    XCTAssertTrue(palette.actions.contains { $0.title == "Scroll to Next Landmark" })
    XCTAssertTrue(palette.actions.contains { $0.title == "Scroll to Last Landmark" })
    palette.dismiss()
    XCTAssertEqual(controller.state, committed)
  }
  func testWalkAccessibilityActionsAndDisplayAccommodationsPreservePlainText() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert("first\nsecond", range: NSRange(location: 0, length: 0), into: controller)
    controller.mutateLandmark(.landmark(Landmark(lineID: controller.state.lines[0].id, emoji: "🌲")))
    let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)

    // Full Keyboard Access activates controls without pointer-only behavior.
    controller.footer.landmarks.performClick(nil)
    settlePresentation(controller)
    XCTAssertTrue(ruler.landmarkMode)
    let entry = try XCTUnwrap(
      ruler.subviews.compactMap { $0 as? NSButton }.first { $0.title == "🌲" })
    XCTAssertEqual(entry.accessibilityLabel(), "🌲, line 1, navigate")
    entry.performClick(nil)
    XCTAssertFalse(ruler.landmarkMode)
    XCTAssertEqual(controller.textView.selectedRange().location, controller.state.lines[0].location)
    XCTAssertTrue(window.firstResponder === controller.textView)

    // Walk has no animations and keeps its controls usable at enlarged text sizes.
    controller.textView.font = .monospacedSystemFont(ofSize: 32, weight: .regular)
    controller.view.layoutSubtreeIfNeeded()
    settlePresentation(controller)
    controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    ruler.refreshControls()
    XCTAssertTrue(controller.footer.landmarks.isEnabled)
    XCTAssertEqual(controller.textView.accessibilityValue(), "first\nsecond")
  }
  func testEmojiPickerValidationAndDetachedResolutionActions() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    let picker = EmojiPicker(parent: window, emoji: nil)
    XCTAssertNotNil(picker)
    insert("a\nb", range: NSRange(location: 0, length: 0), into: controller)
    let landmark = Landmark(lineID: controller.state.lines[0].id, emoji: "🦊")
    controller.mutateLandmark(.landmark(landmark))
    insert("", range: NSRange(location: 0, length: 2), into: controller)
    XCTAssertTrue(try XCTUnwrap(controller.state.landmarks.first).detached)
    let repair = try XCTUnwrap(controller.paletteActions().first { $0.id.hasPrefix("move.") })
    XCTAssertTrue(repair.enabled())
    repair.execute()
    XCTAssertFalse(try XCTUnwrap(controller.state.landmarks.first).detached)
    XCTAssertEqual(controller.state.landmarks.first?.id, landmark.id)
    XCTAssertEqual(controller.state.text, "b")
  }
}
