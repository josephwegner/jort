import XCTest
import AppKit
import Darwin
import JortDocument
import JortPersistence
@testable import JortAppKit

@MainActor final class EditorTests: XCTestCase {
    private func editor() throws -> (EditorViewController, NSWindow) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorTest-\(UUID())")
        let controller = EditorViewController(persistence: PersistenceController(directory: root))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller; window.setContentSize(NSSize(width: 600, height: 400)); window.makeKeyAndOrderFront(nil)
        let loaded = expectation(for: NSPredicate { _, _ in controller.textView.isEditable }, evaluatedWith: nil)
        wait(for: [loaded], timeout: 5)
        XCTAssertTrue(controller.textView.isEditable)
        XCTAssertTrue(controller.textView.isSelectable)
        XCTAssertTrue(controller.textView.acceptsFirstResponder)
        window.makeFirstResponder(controller.textView)
        XCTAssertTrue(window.firstResponder === controller.textView)
        controller.textView.history.groupsByEvent = false
        return (controller, window)
    }
    private func insert(_ text: String, range: NSRange, into controller: EditorViewController) {
        controller.textView.history.beginUndoGrouping()
        controller.textView.insertText(text, replacementRange: range)
        controller.textView.history.endUndoGrouping()
    }
    func testNativeRandomUndoRedoUsesCoordinator() throws {
        let (controller, window) = try editor()
        defer { window.orderOut(nil) }
        XCTAssertNotNil(controller.textView.textLayoutManager)
        var seed: UInt64 = 71
        func next(_ count: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int(seed >> 32) % count }
        for _ in 0..<100 {
            let before = controller.state
            let chars = Array(before.text)
            let position = next(chars.count + 1)
            let offset = String(chars.prefix(position)).utf16.count
            insert(["x", "\n", "🦊", " ", "日本語"][next(5)], range: NSRange(location: offset, length: 0), into: controller)
            let after = controller.state
            XCTAssertEqual(after.revision, before.revision + 1)
            controller.textView.undo(nil)
            XCTAssertEqual(controller.state.lines, before.lines)
            XCTAssertEqual(controller.textView.string, before.text)
            controller.textView.redo(nil)
            XCTAssertEqual(controller.state.lines, after.lines)
            XCTAssertEqual(controller.state.revision, before.revision + 3)
            try controller.state.validate()
        }
        let saved = expectation(description: "Latest snapshot saved")
        controller.persistence.flush { XCTAssertTrue($0); saved.fulfill() }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(controller.coordinator.committedRevision, controller.state.revision)
    }
    func testEmptyRowsCompositionAndPlainPaste() throws {
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        insert("asd\na\n\nasd\n", range: NSRange(location: 0, length: 0), into: controller)
        controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
        let rows = ruler.visibleRows()
        XCTAssertEqual(rows.map(\.number), [1, 2, 3, 4, 5])
        for (a, b) in zip(rows, rows.dropFirst()) { XCTAssertEqual(b.y - a.y, 24, accuracy: 0.5) }
        let before = controller.state
        controller.textView.history.beginUndoGrouping()
        controller.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: before.text.utf16.count, length: 0))
        XCTAssertEqual(controller.state, before)
        controller.textView.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(controller.state, before)
        controller.textView.unmarkText(); controller.textView.history.endUndoGrouping()
        XCTAssertTrue(controller.state.text.hasSuffix("日本語"))
        XCTAssertEqual(controller.state.revision, before.revision + 1)
        controller.textView.undo(nil)
        XCTAssertEqual(controller.state.lines, before.lines)
        XCTAssertFalse(controller.textView.isRichText)
    }
    func testProgrammaticInsertionPreservesSelectionAndIsUndoable() throws {
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        insert("first\nsecond\nthird", range: NSRange(location: 0, length: 0), into: controller)
        let before = controller.state
        controller.textView.setSelectedRange(NSRange(location: 6, length: 6))
        controller.textView.history.beginUndoGrouping()
        let result = try controller.apply(.init(baseRevision: before.revision, origin: .automation,
            mutation: .insertAfter(lineID: before.lines[0].id, text: "output")))
        controller.textView.history.endUndoGrouping()
        let selected = (controller.textView.string as NSString).substring(with: controller.textView.selectedRange())
        XCTAssertEqual(selected, "second")
        XCTAssertEqual(result.after.revision, before.revision + 1)
        controller.textView.undo(nil)
        XCTAssertEqual(controller.state.text, before.text)
        XCTAssertEqual(controller.state.lines, before.lines)
        XCTAssertThrowsError(try controller.apply(.init(baseRevision: before.revision, origin: .automation, mutation: .insertAfter(lineID: before.lines[0].id, text: "stale"))))
    }
    func testReplaceAllAndLargePaste() throws {
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        insert(String(repeating: "hello 🦊\n", count: 1000), range: NSRange(location: 0, length: 0), into: controller)
        let before = controller.state
        let replacement = before.text.replacingOccurrences(of: "hello", with: "goodbye")
        insert(replacement, range: NSRange(location: 0, length: before.text.utf16.count), into: controller)
        try controller.state.validate()
        controller.textView.undo(nil)
        XCTAssertEqual(controller.state.lines, before.lines)
        XCTAssertEqual(controller.state.text, before.text)
    }
    func testLandmarkMutationAndJoinNativeUndo() throws {
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        insert("a\nb\nc", range: NSRange(location: 0, length: 0), into: controller)
        let original = controller.state
        let landmark = Landmark(lineID: original.lines[1].id, emoji: "👩🏽‍💻")
        controller.mutateLandmark(.landmark(landmark))
        XCTAssertEqual(controller.textView.string, original.text)
        XCTAssertEqual(controller.state.lines, original.lines)
        controller.textView.undo(nil); XCTAssertTrue(controller.state.landmarks.isEmpty)
        controller.textView.redo(nil); XCTAssertEqual(controller.state.landmarks, [landmark])
        insert("", range: NSRange(location: 1, length: 1), into: controller)
        XCTAssertEqual(controller.state.landmarks.first?.lineID, original.lines[0].id)
        controller.textView.undo(nil)
        XCTAssertEqual(controller.state.landmarks, [landmark])
        XCTAssertEqual(controller.state.lines, original.lines)
        controller.textView.redo(nil)
        XCTAssertEqual(controller.state.landmarks.first?.lineID, original.lines[0].id)
        XCTAssertEqual(controller.textView.accessibilityValue(), "ab\nc")
        controller.textView.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 0, length: 4))
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        XCTAssertTrue(controller.textView.writeSelection(to: clipboard, types: controller.textView.writablePasteboardTypes))
        XCTAssertEqual(clipboard.string(forType: .string), "ab\nc")
    }
    func testPaletteFilteringDisabledExecutionAndFocusRestoration() throws {
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        insert("hello\nworld", range: NSRange(location: 0, length: 0), into: controller)
        controller.textView.setSelectedRange(NSRange(location: 1, length: 3))
        let selection = controller.textView.selectedRange(), viewport = controller.scroll.contentView.bounds.origin
        let before = controller.state
        controller.showCommandPalette()
        let palette = try XCTUnwrap(controller.palette)
        XCTAssertEqual(palette.window?.accessibilitySubrole(), .dialog)
        XCTAssertEqual(palette.window?.title, "Pocket")
        XCTAssertEqual(palette.window?.accessibilityLabel(), "Pocket")
        palette.query.stringValue = "CLEAR"; palette.reload()
        XCTAssertEqual(palette.results.count, 1)
        XCTAssertFalse(palette.results[0].enabled())
        palette.executeSelection(); XCTAssertNotNil(controller.palette)
        palette.query.stringValue = "nothingmatches"; palette.reload()
        XCTAssertTrue(palette.results.isEmpty)
        XCTAssertEqual(palette.count.stringValue, "No matching actions")
        palette.executeSelection(); XCTAssertEqual(controller.state, before)
        palette.dismiss()
        XCTAssertNil(controller.palette)
        XCTAssertEqual(controller.textView.selectedRange(), selection)
        XCTAssertEqual(controller.scroll.contentView.bounds.origin, viewport)
        XCTAssertTrue(window.firstResponder === controller.textView)
        let action = PaletteAction(id: "test", title: "Réparer", keywords: "detached", execute: {})
        XCTAssertTrue(action.matches("REPARER")); XCTAssertTrue(action.matches("repair") == false)
        XCTAssertTrue(action.matches("DETACHED"))
        controller.mutateLandmark(.landmark(Landmark(lineID: controller.state.lines[0].id, emoji: "🌲")))
        controller.showCommandPalette()
        let changing = try XCTUnwrap(controller.palette)
        changing.query.stringValue = "Clear"; changing.reload()
        XCTAssertTrue(changing.results[0].enabled())
        controller.clearCurrentLandmark()
        XCTAssertFalse(changing.results[0].enabled())
        let revision = controller.state.revision
        changing.executeSelection(); XCTAssertEqual(controller.state.revision, revision)
        changing.dismiss()
    }
    func testPaletteExecutionAndIMEGuard() throws {
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        let before = controller.state
        controller.textView.history.beginUndoGrouping()
        controller.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        controller.showCommandPalette()
        XCTAssertNil(controller.palette); XCTAssertTrue(controller.textView.hasMarkedText()); XCTAssertEqual(controller.state, before)
        controller.textView.unmarkText(); controller.textView.history.endUndoGrouping()
        let committed = controller.state
        controller.showCommandPalette()
        let palette = try XCTUnwrap(controller.palette)
        XCTAssertFalse(palette.actions.contains { $0.id == "landmark.toggle" || $0.id == "app.save" || $0.id == "app.recovery" })
        XCTAssertTrue(palette.actions.contains { $0.title == "Scroll to Next Landmark" })
        XCTAssertTrue(palette.actions.contains { $0.title == "Scroll to Last Landmark" })
        palette.dismiss()
        XCTAssertEqual(controller.state, committed)
    }
    func testGutterDuplicateEmojiResizeAndStaleNavigation() throws {
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        insert("first\n" + String(repeating: "wrapped text ", count: 20) + "\nlast", range: NSRange(location: 0, length: 0), into: controller)
        for line in [controller.state.lines[0], controller.state.lines[2]] {
            controller.mutateLandmark(.landmark(Landmark(lineID: line.id, emoji: "🌲")))
        }
        let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
        let width = controller.textView.frame.width, thickness = ruler.ruleThickness
        controller.toggleLandmarkMode()
        controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        ruler.display()
        XCTAssertEqual(ruler.ruleThickness, thickness); XCTAssertEqual(controller.textView.frame.width, width)
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
        let clear = try XCTUnwrap(ruler.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Clear" })
        XCTAssertFalse(clear.isHidden)
        clear.performClick(nil)
        XCTAssertTrue(controller.state.landmarks.isEmpty)
        XCTAssertFalse(ruler.landmarkMode)
        XCTAssertTrue(clear.isHidden)
        controller.textView.undo(nil)
        XCTAssertEqual(controller.state.landmarks.count, 2)
        let selection = controller.textView.selectedRange()
        controller.navigate(to: UUID()); XCTAssertEqual(controller.textView.selectedRange(), selection)
        window.setContentSize(NSSize(width: 500, height: 350)); controller.view.layoutSubtreeIfNeeded()
        controller.toggleLandmarkMode(); controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport(); ruler.display()
        XCTAssertEqual(ruler.visibleRows().filter { $0.number == 2 }.count, 1)
        if let bitmap = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/jort-walk-gutter.png"))
        }
    }
    func testRulerClipsControlsAndEditorGlyphsRender() throws {
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        insert("VISIBLE GLYPHS", range: NSRange(location: 0, length: 0), into: controller)
        controller.mutateLandmark(.landmark(Landmark(lineID: controller.state.lines[0].id, emoji: "🌲")))
        controller.view.layoutSubtreeIfNeeded()
        controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
        ruler.display()
        XCTAssertTrue(ruler.clipsToBounds)
        XCTAssertEqual(controller.textView.textContainerInset.width, 24)
        let buttons = ruler.subviews.compactMap { $0 as? NSButton }
        let modeButton = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Toggle landmark navigation mode" })
        let landmarkButton = try XCTUnwrap(buttons.first { $0.title == "🌲" })
        XCTAssertEqual(landmarkButton.frame.midX, modeButton.frame.midX, accuracy: 0.5)

        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let background = controller.textView.backgroundColor.usingColorSpace(.deviceRGB)!
        var changedPixels = 0
        for x in 100..<min(bitmap.pixelsWide, 300) {
            for y in 0..<min(bitmap.pixelsHigh, 100) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(color.redComponent - background.redComponent) > 0.1 ||
                    abs(color.greenComponent - background.greenComponent) > 0.1 ||
                    abs(color.blueComponent - background.blueComponent) > 0.1 {
                    changedPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(changedPixels, 20, "Editor glyphs should produce visible pixels outside the gutter")
    }
    func testSustainedEditingAutosaveScrollingAndBoundedUndo() throws {
        let beforeLaunch = ProcessInfo.processInfo.systemUptime
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        let launch = ProcessInfo.processInfo.systemUptime - beforeLaunch
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "canvas-10000", withExtension: "txt"))
        let content = try String(contentsOf: fixture, encoding: .utf8)
        insert(content, range: NSRange(location: 0, length: 0), into: controller)
        for position in stride(from: 0, to: 10000, by: 2000) {
            controller.mutateLandmark(.landmark(Landmark(lineID: controller.state.lines[position].id, emoji: "🌲")))
        }
        var times: [Double] = [], layout: [Double] = [], navigation: [Double] = []
        for index in 0..<40 {
            let line = controller.state.lines[(index * 97) % 10000]
            let navigationStart = ProcessInfo.processInfo.systemUptime
            controller.textView.setSelectedRange(NSRange(location: line.location, length: 0))
            controller.textView.scrollRangeToVisible(NSRange(location: line.location, length: 0))
            controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            navigation.append(ProcessInfo.processInfo.systemUptime - navigationStart)
            let begin = ProcessInfo.processInfo.systemUptime
            insert("x", range: NSRange(location: line.location, length: 0), into: controller)
            times.append(ProcessInfo.processInfo.systemUptime - begin)
            let layoutStart = ProcessInfo.processInfo.systemUptime
            controller.scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index * 48)))
            controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            _ = (controller.scroll.verticalRulerView as? LineRuler)?.visibleRows()
            layout.append(ProcessInfo.processInfo.systemUptime - layoutStart)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(controller.coordinator.committedRevision ?? 0, 0)
        let afterEdits = controller.state
        for _ in 0..<40 { controller.textView.undo(nil) }
        XCTAssertEqual(controller.state.text, content)
        for _ in 0..<40 { controller.textView.redo(nil) }
        XCTAssertEqual(controller.state.lines, afterEdits.lines)
        let saved = expectation(description: "Workflow drains latest save")
        controller.persistence.flush { XCTAssertTrue($0); saved.fulfill() }
        wait(for: [saved], timeout: 10)
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] * 1000 }
        print("PERF native: launch=\(launch * 1000)ms edit p95=\(p95(times))ms navigation p95=\(p95(navigation))ms scroll/gutter p95=\(p95(layout))ms undoGroups=\(controller.textView.history.levelsOfUndo)")
        if ProcessInfo.processInfo.environment["JORT_PERFORMANCE_ENFORCE"] == "1" {
            XCTAssertLessThan(launch, 2)
            XCTAssertLessThan(p95(times), 100)
            XCTAssertLessThan(p95(layout), 100)
        }
    }
    func testWalkLargeDocumentGutterAndNavigation() throws {
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        XCTAssertEqual(CrawlLargeDocument.text.utf16.count, 1_000_000)
        insert(CrawlLargeDocument.text, range: NSRange(location: 0, length: 0), into: controller)
        XCTAssertEqual(controller.state.lines.count, 25_000)
        let initial = controller.state
        let landmarks = stride(from: 0, to: 25_000, by: 100).map { Landmark(lineID: initial.lines[$0].id, emoji: "🌲") }
        controller.textView.history.beginUndoGrouping()
        try controller.apply(.init(baseRevision: initial.revision, origin: .restore, mutation: .restore(DocumentSnapshot(documentID: initial.documentID, text: initial.text, revision: initial.revision, lines: initial.lines, landmarks: landmarks))))
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
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] * 1000 }
        print("PERF Walk 25k: normal gutter p95=\(p95(normal))ms landmark gutter p95=\(p95(index))ms navigation p95=\(p95(navigation))ms")
        XCTAssertEqual(controller.state.text, CrawlLargeDocument.text)
        XCTAssertEqual(ruler.ruleThickness, 48)
        if ProcessInfo.processInfo.environment["JORT_PERFORMANCE_ENFORCE"] == "1" {
            XCTAssertLessThan(p95(normal), 100); XCTAssertLessThan(p95(index), 100); XCTAssertLessThan(p95(navigation), 100)
        }
    }
    func testPaletteNativeFindResponderAndEnlargedGutter() throws {
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        insert("first\nsecond", range: NSRange(location: 0, length: 0), into: controller)
        controller.mutateLandmark(.landmark(Landmark(lineID: controller.state.lines[0].id, emoji: "🌲")))
        let find = NSMenuItem(); find.tag = NSTextFinder.Action.showFindInterface.rawValue
        controller.textView.performFindPanelAction(find)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let previous = window.firstResponder
        controller.showCommandPalette(); try XCTUnwrap(controller.palette).dismiss()
        XCTAssertTrue(window.firstResponder === previous)
        let transient = NSTextField(string: "")
        transient.frame = NSRect(x: 80, y: 0, width: 150, height: 24)
        controller.view.addSubview(transient); window.makeFirstResponder(transient)
        let fieldEditor = try XCTUnwrap(transient.currentEditor() as? NSTextView)
        fieldEditor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        controller.showCommandPalette(); XCTAssertNil(controller.palette); XCTAssertTrue(fieldEditor.hasMarkedText())
        fieldEditor.unmarkText(); window.makeFirstResponder(controller.textView); transient.removeFromSuperview()
        controller.textView.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        controller.view.layoutSubtreeIfNeeded()
        controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
        ruler.refreshControls()
        let mode = try XCTUnwrap(ruler.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Toggle landmark navigation mode" })
        XCTAssertTrue(mode.isEnabled); mode.performClick(nil); XCTAssertTrue(ruler.landmarkMode)
        XCTAssertEqual(controller.textView.accessibilityValue(), "first\nsecond")
    }
    func testEmojiPickerValidationAndDetachedResolutionActions() throws {
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        let picker = EmojiPicker(parent: window, emoji: nil)
        XCTAssertNotNil(picker)
        insert("a\nb", range: NSRange(location: 0, length: 0), into: controller)
        let landmark = Landmark(lineID: controller.state.lines[0].id, emoji: "🦊")
        controller.mutateLandmark(.landmark(landmark))
        insert("", range: NSRange(location: 0, length: 2), into: controller)
        XCTAssertTrue(try XCTUnwrap(controller.state.landmarks.first).detached)
        let repair = try XCTUnwrap(controller.paletteActions().first { $0.id.hasPrefix("move.") })
        XCTAssertTrue(repair.enabled()); repair.execute()
        XCTAssertFalse(try XCTUnwrap(controller.state.landmarks.first).detached)
        XCTAssertEqual(controller.state.landmarks.first?.id, landmark.id)
        XCTAssertEqual(controller.state.text, "b")
    }

}
