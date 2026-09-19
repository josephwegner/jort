import XCTest
import AppKit
import Darwin
import JortDocument
import JortPersistence
@testable import JortAppKit

@MainActor final class RulerGeometryTests: EditorTestCase {
  func testAccessoryExpandsCanonicalLineWithoutTextMutation() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert(
      "one\ntwo\nthree\nfour\nfive\nDecision: content\nNext: content\neight",
      range: NSRange(location: 0, length: 0), into: controller)
    let layout = try XCTUnwrap(controller.linePresentation)
    controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let before = controller.state
    let original = try XCTUnwrap(layout.band(for: before.lines[5].id))
    let originalX = controller.scroll.contentView.bounds.minX
    let title = NSTextField(labelWithString: "Test explanation")
    let actions = NSButton(title: "Test action", target: nil, action: nil)
    layout.setAccessories([
      LineAccessory(lineID: before.lines[4].id, height: 64, view: title),
      LineAccessory(lineID: before.lines[6].id, height: 32, view: actions),
    ])
    let moved = try XCTUnwrap(layout.band(for: before.lines[5].id))
    XCTAssertEqual(moved.textY - original.textY, 64, accuracy: 0.5)
    XCTAssertEqual(moved.number, 6)
    XCTAssertEqual(controller.scroll.contentView.bounds.minX, originalX)
    XCTAssertEqual(controller.state, before)
    XCTAssertEqual(controller.textView.string, before.text)
    XCTAssertEqual(title.superview, controller.textView)
    layout.setAccessories([])
    XCTAssertEqual(
      try XCTUnwrap(layout.band(for: before.lines[5].id)).textY, original.textY, accuracy: 0.5)
    XCTAssertNil(title.superview)
  }
  func testWrappedAccessoriesEditingAndAccessibleOrder() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    let wrapped = String(repeating: "wrapped content ", count: 20)
    insert("first\n\(wrapped)\nlast", range: NSRange(location: 0, length: 0), into: controller)
    let layout = try XCTUnwrap(controller.linePresentation)
    let id = controller.state.lines[1].id
    let label = NSTextField(labelWithString: "Explanation")
    layout.setAccessories([LineAccessory(lineID: id, height: 72, view: label)])
    let band = try XCTUnwrap(layout.band(for: id))
    XCTAssertGreaterThan(try XCTUnwrap(band.accessoryFrame).minY - band.textY, 24)
    let children = try XCTUnwrap(layout.accessibilityChildren())
    let index = try XCTUnwrap(children.firstIndex { ($0 as? NSView) === label })
    XCTAssertEqual((children[index - 1] as? NSAccessibilityElement)?.accessibilityLabel(), "Line 2")
    XCTAssertEqual((children[index + 1] as? NSAccessibilityElement)?.accessibilityLabel(), "Line 3")
    let attrs = controller.textView.typingAttributes
    insert("prefix\n", range: NSRange(location: 0, length: 0), into: controller)
    controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    XCTAssertNotNil(layout.accessories[id])
    XCTAssertEqual(try XCTUnwrap(layout.band(for: id)).number, 3)
    XCTAssertEqual(
      controller.textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle,
      attrs[.paragraphStyle] as? NSParagraphStyle)
    let line = try XCTUnwrap(controller.state.lines.first { $0.id == id })
    insert("", range: NSRange(location: line.location, length: line.length), into: controller)
    XCTAssertNil(layout.accessories[id])
    XCTAssertNil(label.superview)
  }
  func testAccessoryViewportAnchorAndLargeDocumentBudget() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "canvas-10000", withExtension: "txt"))
    insert(
      try String(contentsOf: fixture, encoding: .utf8), range: NSRange(location: 0, length: 0),
      into: controller)
    let layout = try XCTUnwrap(controller.linePresentation)
    let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
    let descriptors = stride(from: 0, to: 10000, by: 20).map { index in
      LineAccessory(
        lineID: controller.state.lines[index].id, height: 48,
        view: NSTextField(labelWithString: "Fixture \(index)"))
    }
    let selection = controller.textView.selectedRange()
    layout.setAccessories(descriptors)
    var samples: [Double] = []
    for index in 0..<30 {
      controller.navigate(to: controller.state.lines[(index * 197) % 10000].id)
      controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
      let start = ProcessInfo.processInfo.systemUptime
      ruler.optionHeld = index.isMultiple(of: 2)
      _ = ruler.visibleRows()
      layout.refreshViews()
      samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      XCTAssertLessThan(layout.visibleBands().count, 100)
      XCTAssertLessThan(controller.textView.subviews.count, 100)
    }
    samples.sort()
    let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
    print("PERF shell: 10k lines / 500 accessories, visible layout + Option p95=\(p95)ms")
    XCTAssertLessThan(p95, 100)
    settlePresentation(controller)
    let anchor = try XCTUnwrap(layout.viewportAnchor())
    let selected = controller.textView.selectedRange()
    layout.setAccessories([])
    settlePresentation(controller)
    let restored = try XCTUnwrap(layout.viewportAnchor())
    XCTAssertEqual(restored.0, anchor.0)
    XCTAssertEqual(restored.1, anchor.1, accuracy: 1)
    XCTAssertEqual(controller.textView.selectedRange(), selected)
    XCTAssertTrue(window.firstResponder === controller.textView)
    controller.textView.setSelectedRange(selection)
  }
  func testEmptyRowsCompositionAndPlainPaste() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert("asd\na\n\nasd\n", range: NSRange(location: 0, length: 0), into: controller)
    controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
    settlePresentation(controller)
    let rows = ruler.visibleRows()
    XCTAssertEqual(rows.map(\.number), [1, 2, 3, 4, 5])
    for (a, b) in zip(rows, rows.dropFirst()) { XCTAssertEqual(b.y - a.y, 24, accuracy: 0.5) }
    let before = controller.state
    controller.textView.history.beginUndoGrouping()
    controller.textView.setMarkedText(
      "に", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: before.text.utf16.count, length: 0))
    XCTAssertEqual(controller.state, before)
    controller.textView.setMarkedText(
      "日本語", selectedRange: NSRange(location: 3, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertEqual(controller.state, before)
    controller.textView.unmarkText()
    controller.textView.history.endUndoGrouping()
    XCTAssertTrue(controller.state.text.hasSuffix("日本語"))
    XCTAssertEqual(controller.state.revision, before.revision + 1)
    controller.textView.undo(nil)
    XCTAssertEqual(controller.state.lines, before.lines)
    XCTAssertFalse(controller.textView.isRichText)
  }
  func testGutterDuplicateEmojiResizeAndStaleNavigation() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert(
      "first\n" + String(repeating: "wrapped text ", count: 20) + "\nlast",
      range: NSRange(location: 0, length: 0), into: controller)
    for line in [controller.state.lines[0], controller.state.lines[2]] {
      controller.mutateLandmark(.landmark(Landmark(lineID: line.id, emoji: "🌲")))
    }
    let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
    let width = controller.textView.frame.width, thickness = ruler.ruleThickness
    controller.toggleLandmarkMode()
    controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    settlePresentation(controller)
    ruler.display()
    XCTAssertEqual(ruler.ruleThickness, thickness)
    XCTAssertEqual(controller.textView.frame.width, width)
    let entries = ruler.subviews.compactMap { $0 as? NSButton }.filter { $0.title == "🌲" }
    XCTAssertEqual(entries.count, 2)
    guard entries.count == 2 else { return }
    XCTAssertNotEqual(entries[0].accessibilityLabel(), entries[1].accessibilityLabel())
    XCTAssertEqual(entries[0].toolTip, "first")
    XCTAssertEqual(entries[1].toolTip, "last")
    entries[1].performClick(nil)
    XCTAssertEqual(controller.textView.selectedRange().location, controller.state.lines[2].location)
    XCTAssertFalse(ruler.landmarkMode)
    XCTAssertTrue(window.firstResponder === controller.textView)
    controller.toggleLandmarkMode()
    settlePresentation(controller)
    let clear = try XCTUnwrap(
      ruler.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Clear" })
    XCTAssertFalse(clear.isHidden)
    clear.performClick(nil)
    settlePresentation(controller)
    XCTAssertTrue(controller.state.landmarks.isEmpty)
    XCTAssertFalse(ruler.landmarkMode)
    XCTAssertTrue(clear.isHidden)
    controller.textView.undo(nil)
    XCTAssertEqual(controller.state.landmarks.count, 2)
    let selection = controller.textView.selectedRange()
    controller.navigate(to: UUID())
    XCTAssertEqual(controller.textView.selectedRange(), selection)
    window.setContentSize(NSSize(width: 500, height: 350))
    controller.view.layoutSubtreeIfNeeded()
    settlePresentation(controller)
    controller.toggleLandmarkMode()
    controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    settlePresentation(controller)
    ruler.display()
    XCTAssertEqual(ruler.visibleRows().filter { $0.number == 2 }.count, 1)
    if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
      controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])?.write(
        to: URL(fileURLWithPath: "/private/tmp/jort-walk-gutter.png"))
    }
  }
  func testRulerClipsControlsAndEditorGlyphsRender() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert("VISIBLE GLYPHS", range: NSRange(location: 0, length: 0), into: controller)
    controller.mutateLandmark(.landmark(Landmark(lineID: controller.state.lines[0].id, emoji: "🌲")))
    controller.view.layoutSubtreeIfNeeded()
    settlePresentation(controller)
    controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
    settlePresentation(controller)
    ruler.display()
    XCTAssertTrue(ruler.clipsToBounds)
    XCTAssertEqual(controller.textView.textContainerInset.width, 12)
    XCTAssertEqual(controller.textView.textContainerInset.height, 0)
    let buttons = ruler.subviews.compactMap { $0 as? NSButton }
    XCTAssertFalse(
      buttons.contains { $0.accessibilityLabel() == "Toggle landmark navigation mode" })
    let landmarkButton = try XCTUnwrap(buttons.first { $0.title == "🌲" })
    XCTAssertEqual(landmarkButton.frame.midX, EditorMetrics.gutterWidth / 2, accuracy: 0.5)

    let bitmap = try XCTUnwrap(
      controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
    let background = controller.textView.backgroundColor.usingColorSpace(.deviceRGB)!
    var changedPixels = 0
    for x in 100..<min(bitmap.pixelsWide, 300) {
      for y in 0..<min(bitmap.pixelsHigh, 100) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if abs(color.redComponent - background.redComponent) > 0.1
          || abs(color.greenComponent - background.greenComponent) > 0.1
          || abs(color.blueComponent - background.blueComponent) > 0.1
        {
          changedPixels += 1
        }
      }
    }
    XCTAssertGreaterThan(
      changedPixels, 20, "Editor glyphs should produce visible pixels outside the gutter")
  }
  func testWalkLargeDocumentGutterAndNavigation() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    XCTAssertEqual(CrawlLargeDocument.text.utf16.count, 1_000_000)
    insert(CrawlLargeDocument.text, range: NSRange(location: 0, length: 0), into: controller)
    XCTAssertEqual(controller.state.lines.count, 25_000)
    let initial = controller.state
    let landmarks = stride(from: 0, to: 25_000, by: 100).map {
      Landmark(lineID: initial.lines[$0].id, emoji: "🌲")
    }
    controller.textView.history.beginUndoGrouping()
    try controller.apply(
      .init(
        baseRevision: initial.revision, origin: .restore,
        mutation: .restore(
          DocumentSnapshot(
            documentID: initial.documentID, text: initial.text, revision: initial.revision,
            lines: initial.lines, landmarks: landmarks))))
    controller.textView.history.endUndoGrouping()
    let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
    var normal: [Double] = [], index: [Double] = [], navigation: [Double] = []
    for mode in [false, true] {
      ruler.landmarkMode = mode
      for iteration in 0..<20 {
        let target = landmarks[(iteration * 37) % landmarks.count]
        let begin = ProcessInfo.processInfo.systemUptime
        controller.navigate(to: target.lineID)
        navigation.append(ProcessInfo.processInfo.systemUptime - begin)
        let start = ProcessInfo.processInfo.systemUptime
        controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        ruler.refreshControls()
        XCTAssertLessThan(ruler.visibleRows().count, 100)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if mode { index.append(elapsed) } else { normal.append(elapsed) }
      }
    }
    func p95(_ values: [Double]) -> Double {
      values.sorted()[Int(Double(values.count - 1) * 0.95)] * 1000
    }
    print(
      "PERF Walk 25k: normal gutter p95=\(p95(normal))ms landmark gutter p95=\(p95(index))ms navigation p95=\(p95(navigation))ms"
    )
    XCTAssertEqual(controller.state.text, CrawlLargeDocument.text)
    XCTAssertEqual(ruler.ruleThickness, 48)
    if ProcessInfo.processInfo.environment["JORT_PERFORMANCE_ENFORCE"] == "1" {
      XCTAssertLessThan(p95(normal), 100)
      XCTAssertLessThan(p95(index), 100)
      XCTAssertLessThan(p95(navigation), 100)
    }
  }
  func testPaletteNativeFindResponderAndEnlargedGutter() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert("first\nsecond", range: NSRange(location: 0, length: 0), into: controller)
    controller.mutateLandmark(.landmark(Landmark(lineID: controller.state.lines[0].id, emoji: "🌲")))
    let find = NSMenuItem()
    find.tag = NSTextFinder.Action.showFindInterface.rawValue
    controller.textView.performFindPanelAction(find)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let previous = window.firstResponder
    controller.showCommandPalette()
    try XCTUnwrap(controller.palette).dismiss()
    XCTAssertTrue(window.firstResponder === previous)
    let transient = NSTextField(string: "")
    transient.frame = NSRect(x: 80, y: 0, width: 150, height: 24)
    controller.view.addSubview(transient)
    window.makeFirstResponder(transient)
    let fieldEditor = try XCTUnwrap(transient.currentEditor() as? NSTextView)
    fieldEditor.setMarkedText(
      "に", selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: 0, length: 0))
    controller.showCommandPalette()
    XCTAssertNil(controller.palette)
    XCTAssertTrue(fieldEditor.hasMarkedText())
    fieldEditor.unmarkText()
    window.makeFirstResponder(controller.textView)
    transient.removeFromSuperview()
    controller.textView.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
    controller.view.layoutSubtreeIfNeeded()
    settlePresentation(controller)
    controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
    ruler.refreshControls()
    XCTAssertFalse(
      ruler.subviews.compactMap { $0 as? NSButton }.contains {
        $0.accessibilityLabel() == "Toggle landmark navigation mode"
      })
    XCTAssertTrue(controller.footer.landmarks.isEnabled)
    controller.footer.landmarks.performClick(nil)
    XCTAssertTrue(ruler.landmarkMode)
    XCTAssertEqual(controller.textView.accessibilityValue(), "first\nsecond")
  }
}
