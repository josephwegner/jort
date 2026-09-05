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
        window.makeFirstResponder(controller.textView)
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
    func testSustainedEditingAutosaveScrollingAndBoundedUndo() throws {
        let beforeLaunch = ProcessInfo.processInfo.systemUptime
        let (controller, window) = try editor(); defer { window.orderOut(nil) }
        let launch = ProcessInfo.processInfo.systemUptime - beforeLaunch
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "canvas-10000", withExtension: "txt"))
        let content = try String(contentsOf: fixture, encoding: .utf8)
        insert(content, range: NSRange(location: 0, length: 0), into: controller)
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

}
