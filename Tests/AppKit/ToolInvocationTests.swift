import XCTest
import AppKit
import JortDocument
import JortPersistence
import JortSettings
@testable import JortAppKit

@MainActor final class ToolInvocationTests: XCTestCase {
    private func editor() async throws -> (EditorViewController, NSWindow) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ToolEditor-\(UUID())")
        let editor = EditorViewController(persistence: PersistenceController(directory: directory))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = editor
        window.setContentSize(NSSize(width: 600, height: 400)); window.makeKeyAndOrderFront(nil)
        for _ in 0..<500 where editor.coordinator.onTransaction == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(editor.textView.isEditable)
        return (editor, window)
    }
    private func package(_ command: String, mode: ToolInputMode = .contained, output: String = "6") -> ToolPackage {
        let encoded = String(data: try! JSONEncoder().encode(output), encoding: .utf8)!
        return .init(manifest: .init(id: "dev.test." + command, name: command, command: "/" + command, inputMode: mode),
              source: "export default async function(input) { return {output: \(encoded)}; }")
    }
    private func pending(_ editor: EditorViewController) async throws {
        for _ in 0..<500 {
            if editor.state.invocations.first?.phase == .pending { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Tool did not enter pending: \(editor.state.invocations)")
    }
    func testContainedCanonicalPublicationLockMergeAndUndo() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        let package = package("calc"); editor.toolPackages = [package]
        editor.textView.insertText("I need /calc apples", replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(package, token: NSRange(location: 7, length: 5), space: true)
        XCTAssertEqual(editor.state.invocations.count, 1, "After accept: \(editor.state)")
        XCTAssertEqual(editor.textView.selectedRange().location, 13)
        XCTAssertEqual(editor.textView.selectedRange().length, 0)
        XCTAssertEqual(editor.state.text, "I need /calc  apples")
        XCTAssertEqual(editor.textView.string, editor.state.text)
        editor.textView.insertText("3+3", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(editor.state.invocations.count, 1, "After typing: \(editor.state)")
        let id = try XCTUnwrap(editor.state.invocations.first?.id)
        XCTAssertEqual(editor.toolController.content(editor.state.invocations[0]), " 3+3")
        editor.toolController.submit(id)
        try await pending(editor)
        XCTAssertFalse(editor.textView(editor.textView, shouldChangeTextIn: NSRange(location: 8, length: 1), replacementString: "X"))
        XCTAssertEqual(editor.state.text, "I need /calc 3+36 apples")
        XCTAssertTrue(editor.state.invocations[0].validated(in: editor.state))
        window.setContentSize(NSSize(width: 600, height: 400))
        editor.view.layoutSubtreeIfNeeded()
        editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshToolPresentation()
        let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
        editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/jort-tools-pending.png"))
        try editor.toolController.merge(id)
        XCTAssertEqual(editor.state.text, "I need 6 apples"); XCTAssertTrue(editor.state.invocations.isEmpty)
        editor.textView.history.undo()
        XCTAssertEqual(editor.state.invocations.first?.phase, .pending)
    }
    func testContextExcludesOnlyTokenAndDismissRestores() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        let package = package("dedupe", mode: .contextual, output: "done"); editor.toolPackages = [package]
        editor.textView.insertText("apples /dedupe pears\nnext", replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(package, token: NSRange(location: 7, length: 7), space: false)
        let invocation = try XCTUnwrap(editor.state.invocations.first)
        XCTAssertEqual(editor.toolController.content(invocation), "apples  pears")
        let before = editor.state.text
        editor.toolController.submit(invocation.id); try await pending(editor)
        XCTAssertEqual(editor.state.text, "apples /dedupedone pears\nnext")
        try editor.toolController.dismiss(invocation.id)
        XCTAssertEqual(editor.state.text, before); XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
        editor.toolController.submit(invocation.id); try await pending(editor)
        try editor.toolController.merge(invocation.id)
        XCTAssertEqual(editor.state.text, "done\nnext")
    }
    func testEmptyOutputAndEphemeralPromptNeverPersist() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        let package = package("write", mode: .ephemeralMultiline, output: ""); editor.toolPackages = [package]
        editor.textView.insertText("/write", replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(package, token: NSRange(location: 0, length: 6), space: true)
        let id = try XCTUnwrap(editor.state.invocations.first?.id)
        editor.toolController.prompts[id] = "Secret prompt"
        XCTAssertFalse(String(data: try PersistenceFormat.encode(editor.state), encoding: .utf8)!.contains("Secret prompt"))
        editor.toolController.submit(id); try await pending(editor)
        XCTAssertEqual(editor.state.text, "/write")
        try editor.toolController.merge(id); XCTAssertEqual(editor.state.text, "")
    }
    func testConnectedUnionRemovesSharedInteriorEdges() {
        let path = ToolInvocationPresentation.union([NSRect(x: 50, y: 0, width: 100, height: 20), NSRect(x: 0, y: 18, width: 150, height: 20), NSRect(x: 0, y: 36, width: 80, height: 20)])
        XCTAssertTrue(path.contains(NSPoint(x: 70, y: 19)))
        XCTAssertTrue(path.contains(NSPoint(x: 70, y: 37)))
        XCTAssertFalse(path.contains(NSPoint(x: 20, y: 5)))
        XCTAssertEqual(path.bounds, NSRect(x: 0, y: 0, width: 150, height: 56))
    }
    func testMultilineContainedAndTwoConcurrentInvocations() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        let package = package("calc"); editor.toolPackages = [package]
        editor.textView.insertText("/calc end /calc", replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: true)
        editor.textView.insertText("first\nsecond", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(editor.state.invocations.count, 1)
        XCTAssertEqual(editor.state.lines.count, 2)
        let last = (editor.state.text as NSString).range(of: "/calc", options: .backwards)
        try editor.toolController.accept(package, token: last, space: false)
        XCTAssertEqual(editor.state.invocations.count, 2)
        let ids = editor.state.invocations.map(\.id)
        for id in ids { editor.toolController.submit(id) }
        for _ in 0..<500 {
            if editor.state.invocations.allSatisfy({ $0.phase == .pending }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(editor.state.invocations.allSatisfy { $0.phase == .pending })
        XCTAssertTrue(editor.state.invocations.allSatisfy { $0.validated(in: editor.state) })
        for id in ids { try editor.toolController.merge(id) }
        XCTAssertEqual(editor.state.text, "6 end 6")
    }
    func testValidationCancelAndPackageChangeDoNotPublishLateOutput() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        var package = package("test")
        package.source = "export async function validate(input) { return {error: 'Please revise'}; } export default async function() { return {output:'never'}; }"
        editor.toolPackages = [package]
        editor.textView.insertText("/test", replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: false)
        let id = try XCTUnwrap(editor.state.invocations.first?.id)
        editor.toolController.submit(id)
        for _ in 0..<500 where editor.state.invocations.first?.message == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
        XCTAssertEqual(editor.state.invocations.first?.message, "Please revise")
        XCTAssertEqual(editor.state.text, "/test")
        editor.toolController.cancel(id)
        XCTAssertTrue(editor.state.invocations.isEmpty)
        package.source = "export default async function() { while(true) {} }"
        editor.toolPackages = [package]
        try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: false)
        let runningID = try XCTUnwrap(editor.state.invocations.first?.id)
        editor.toolController.submit(runningID)
        for _ in 0..<500 where editor.state.invocations.first?.phase == .inputting { try await Task.sleep(for: .milliseconds(10)) }
        editor.toolController.cancel(runningID)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(editor.state.text, "/test"); XCTAssertTrue(editor.state.invocations.isEmpty)
    }
    func testRenderedWrappedMultilineAndProcessingStates() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        func capture(_ name: String) throws {
            window.setContentSize(NSSize(width: 600, height: 400))
            editor.view.layoutSubtreeIfNeeded()
            editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            editor.refreshToolPresentation()
            let bitmap = try XCTUnwrap(editor.view.bitmapImageRepForCachingDisplay(in: editor.view.bounds))
            editor.view.cacheDisplay(in: editor.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/jort-tools-\(name).png"))
        }
        let package = package("calc", output: "Result line one\nResult line two")
        editor.toolPackages = [package]
        let prefix = "The orchard estimate is "
        editor.textView.insertText(prefix + "/calc for the fall order.", replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(package, token: NSRange(location: prefix.utf16.count, length: 5), space: true)
        editor.textView.insertText("(apples + pears) * crates_per_row\n+ extra_crates", replacementRange: editor.textView.selectedRange())
        let id = try XCTUnwrap(editor.state.invocations.first?.id)
        try capture("contained-multiline")
        editor.toolController.submit(id); try await pending(editor)
        try capture("multiline-pending")
        XCTAssertEqual(editor.state.lines.count, 3)
        XCTAssertTrue(editor.state.invocations[0].validated(in: editor.state))
        let persisted = try PersistenceFormat.decode(PersistenceFormat.encode(editor.state)).snapshot
        XCTAssertEqual(persisted, editor.state)
        try editor.toolController.dismiss(id)
        editor.toolController.cancel(id)
        var slow = package; slow.source = "export default async function() { while(true) {} }"
        editor.toolPackages = [slow]
        let token = (editor.state.text as NSString).range(of: "/calc")
        try editor.toolController.accept(slow, token: token, space: false)
        let running = try XCTUnwrap(editor.state.invocations.first?.id)
        editor.toolController.submit(running)
        for _ in 0..<300 where editor.state.invocations.first?.phase != .processing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(editor.state.invocations.first?.phase, .processing)
        try capture("processing")
        editor.toolController.cancel(running)
    }
    func testKeyboardCompletionAcceptanceSubmissionAndPlainPaste() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        editor.toolPackages = [package("calc")]
        func key(_ characters: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            editor.textView.keyDown(with: event)
        }
        window.makeFirstResponder(editor.textView)
        key("/", code: 44); key("ca"); key("\r", code: 36)
        XCTAssertEqual(editor.state.text, "/calc")
        XCTAssertEqual(editor.state.invocations.first?.phase, .inputting)
        XCTAssertEqual(editor.toolController.content(editor.state.invocations[0]), "")
        key("3+3"); key("\r", code: 36, modifiers: .shift)
        try await pending(editor)
        XCTAssertEqual(editor.state.text, "/calc3+36")
        let actions = editor.textView.subviews.compactMap { ($0 as? NSButton)?.accessibilityLabel() }
        XCTAssertTrue(actions.contains("Merge")); XCTAssertTrue(actions.contains("Dismiss"))
        let id = editor.state.invocations[0].id
        try editor.toolController.dismiss(id); editor.toolController.cancel(id)
        editor.textView.setSelectedRange(NSRange(location: editor.state.text.utf16.count, length: 0))
        editor.toolPresentation.abandonCompletion()
        editor.textView.isPasting = true
        editor.textView.insertText(" /calc", replacementRange: editor.textView.selectedRange())
        editor.textView.isPasting = false
        key(" ", code: 49)
        XCTAssertTrue(editor.state.invocations.isEmpty)
    }
    func testPackageMappingPreservesCompletedOutputAndContext() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        var package = package("dedupe", mode: .contextual, output: "result")
        editor.toolPackages = [package]
        editor.textView.insertText("source /dedupe tail", replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(package, token: NSRange(location: 7, length: 7), space: false)
        let id = editor.state.invocations[0].id
        editor.toolController.submit(id); try await pending(editor)
        package.manifest.version = 2; package.manifest.compatibleVersions = [1]
        editor.toolPackages = [package]
        XCTAssertEqual(editor.state.invocations[0].packageVersion, 2)
        XCTAssertEqual(editor.state.invocations[0].phase, .pending)
        package.manifest.version = 3; package.manifest.compatibleVersions = nil
        editor.toolPackages = [package]
        XCTAssertEqual(editor.state.text, "source result tail")
        XCTAssertTrue(editor.state.invocations.isEmpty)
    }

    func testEphemeralDismissRestoresPromptAndTransfersFocus() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        let package = package("write", mode: .ephemeralMultiline, output: "Customer email")
        editor.toolPackages = [package]
        editor.textView.insertText("/write", replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(package, token: NSRange(location: 0, length: 6), space: false)
        let id = editor.state.invocations[0].id
        let input = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(input === editor.textView)
        input.insertText("Write about new SKUs\nKeep it concise", replacementRange: input.selectedRange())
        XCTAssertEqual(editor.toolController.prompts[id], input.string)
        editor.toolController.submit(id); try await pending(editor)
        XCTAssertTrue(window.firstResponder === editor.textView)
        try editor.toolController.dismiss(id)
        let restored = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(restored === editor.textView)
        XCTAssertEqual(restored.string, "Write about new SKUs\nKeep it concise")
        restored.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(editor.state.invocations.isEmpty)
        XCTAssertNil(editor.toolController.prompts[id])
        XCTAssertEqual(editor.state.text, "/write")
    }

    func testDecorationAttributesFollowEditsAndDisappearOnCancel() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        let package = package("calc"); editor.toolPackages = [package]
        editor.textView.insertText("before /calc after", replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(package, token: NSRange(location: 7, length: 5), space: true)
        let id = editor.state.invocations[0].id
        editor.textView.insertText("prefix ", replacementRange: NSRange(location: 0, length: 0))
        editor.toolController.cancel(id)
        let storage = try XCTUnwrap(editor.textView.textStorage)
        storage.enumerateAttribute(.kern, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            XCTAssertEqual((value as? NSNumber)?.doubleValue ?? 0, 0)
        }
        XCTAssertEqual(editor.state.text, "prefix before /calc  after")
    }

    func testInsertAtInvocationKeepsContextAndEmptyReplaceContext() async throws {
        for empty in [false, true] {
            let (editor, window) = try await editor(); defer { window.orderOut(nil) }
            var package = package("test", mode: .contextual, output: empty ? "" : "RESULT")
            package.manifest.outputOperation = empty ? .replaceContext : .insertAtInvocation
            editor.toolPackages = [package]
            editor.textView.insertText("before /test after\nnext", replacementRange: NSRange(location: 0, length: 0))
            try editor.toolController.accept(package, token: NSRange(location: 7, length: 5), space: false)
            let id = editor.state.invocations[0].id
            editor.toolController.submit(id); try await pending(editor)
            try editor.toolController.merge(id)
            XCTAssertEqual(editor.state.text, empty ? "\nnext" : "before RESULT after\nnext")
            editor.textView.history.undo()
            XCTAssertEqual(editor.state.invocations.first?.phase, .pending)
            editor.textView.history.redo()
            XCTAssertEqual(editor.state.text, empty ? "\nnext" : "before RESULT after\nnext")
        }
    }

    func testCrawlLargeDocumentToolPipelineDistributions() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        let package = package("test", mode: .contextual, output: "RESULT")
        editor.toolPackages = [package]
        editor.textView.insertText("/test\n" + CrawlLargeDocument.text, replacementRange: NSRange(location: 0, length: 0))
        var parse: [Double] = [], geometry: [Double] = [], movement: [Double] = [], lifecycle: [Double] = [], commit: [Double] = []
        func clock() -> Double { ProcessInfo.processInfo.systemUptime }
        for _ in 0..<6 {
            var start = clock()
            try editor.toolController.accept(package, token: NSRange(location: 0, length: 5), space: false)
            parse.append(clock() - start)
            let id = editor.state.invocations[0].id
            start = clock()
            try editor.toolController.moveBoundary(id, start: false, to: editor.state.text.utf16.count)
            movement.append(clock() - start)
            start = clock(); editor.refreshToolPresentation(); geometry.append(clock() - start)
            // A bounded prefix fits the execution cap while retaining the large document.
            try editor.toolController.moveBoundary(id, start: false, to: 100)
            start = clock(); editor.toolController.submit(id); try await pending(editor); lifecycle.append(clock() - start)
            start = clock(); try editor.toolController.dismiss(id); commit.append(clock() - start)
            editor.toolController.cancel(id)
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1] * 1000 }
        print("PERF Tools CrawlLargeDocument ms p95: recognition+accept=\(p95(parse)), geometry=\(p95(geometry)), full-context-movement=\(p95(movement)), submit+publish=\(p95(lifecycle)), dismiss-commit=\(p95(commit))")
        XCTAssertEqual(editor.state.text, "/test\n" + CrawlLargeDocument.text)
    }

    func testIMECommitBoundaryMatchingAndLockedPlainCopy() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        editor.toolPackages = [package("calc")]
        window.makeFirstResponder(editor.textView)
        editor.textView.setMarkedText("/calc", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 0))
        editor.refreshToolPresentation()
        XCTAssertTrue(editor.state.invocations.isEmpty)
        XCTAssertFalse(editor.textView.subviews.contains { ($0 as? NSButton)?.accessibilityLabel() == "/calc  calc" })
        editor.textView.unmarkText(); editor.refreshToolPresentation()
        let accept = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        editor.textView.keyDown(with: accept)
        XCTAssertEqual(editor.state.invocations.count, 1)
        let id = try XCTUnwrap(editor.state.invocations.first?.id)
        editor.toolController.submit(id); try await pending(editor)
        editor.textView.setSelectedRange(NSRange(location: 0, length: editor.state.text.utf16.count))
        editor.textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), editor.state.text)
        XCTAssertTrue(NSPasteboard.general.types?.allSatisfy { [.string, NSPasteboard.PasteboardType("NSStringPboardType")].contains($0) } == true)
        let before = editor.state
        editor.textView.insertText("replacement", replacementRange: editor.textView.selectedRange())
        XCTAssertEqual(editor.state, before)
        XCTAssertEqual(editor.textView.string, before.text)
        try editor.toolController.dismiss(id); editor.toolController.cancel(id)
        editor.textView.setSelectedRange(NSRange(location: editor.state.text.utf16.count, length: 0))
        editor.textView.insertText("(", replacementRange: editor.textView.selectedRange())
        editor.textView.insertText("/", replacementRange: editor.textView.selectedRange())
        editor.textView.insertText("calc", replacementRange: editor.textView.selectedRange())
        editor.textView.keyDown(with: accept)
        XCTAssertTrue(editor.state.invocations.isEmpty)
    }

    func testContextHandlesClampPendingOutputAndComposedCharacters() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        let contained = package("calc", output: "RESULT"), contextual = package("sort", mode: .contextual)
        editor.toolPackages = [contained, contextual]
        editor.textView.insertText("/calc\n🦊 before /sort after", replacementRange: NSRange(location: 0, length: 0))
        try editor.toolController.accept(contained, token: NSRange(location: 0, length: 5), space: false)
        let first = editor.state.invocations[0].id
        editor.toolController.submit(first); try await pending(editor)
        let token = (editor.state.text as NSString).range(of: "/sort")
        try editor.toolController.accept(contextual, token: token, space: false)
        let context = try XCTUnwrap(editor.state.invocations.first { $0.id != first })
        let original = try XCTUnwrap(context.scope.resolve(in: editor.state.lines))
        try editor.toolController.moveBoundary(context.id, start: true, to: original.location + 1)
        XCTAssertEqual(editor.state.invocations.first { $0.id == context.id }?.scope.resolve(in: editor.state.lines)?.location, original.location)
        try editor.toolController.moveBoundary(context.id, start: true, to: 0)
        XCTAssertEqual(editor.state.invocations.first { $0.id == context.id }?.scope.resolve(in: editor.state.lines)?.location, 11)
        XCTAssertTrue(editor.state.invocations.allSatisfy { $0.validated(in: editor.state) })
        editor.refreshToolPresentation()
        let handles = editor.textView.subviews.filter { $0.accessibilityRole() == .slider }
        XCTAssertEqual(Set(handles.compactMap { $0.accessibilityLabel() }), ["Context start", "Context end"])
    }

    func testEphemeralPromptFitsNarrowWindowAndFollowsAnchorOffscreen() async throws {
        let (editor, window) = try await editor(); defer { window.orderOut(nil) }
        let package = package("write", mode: .ephemeralMultiline)
        editor.toolPackages = [package]
        let text = "A customer email /write\n" + String(repeating: "Document line\n", count: 200)
        editor.textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0)); editor.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        try editor.toolController.accept(package, token: (text as NSString).range(of: "/write"), space: false)
        window.setContentSize(NSSize(width: 360, height: 400)); editor.view.layoutSubtreeIfNeeded()
        editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport(); editor.refreshToolPresentation()
        let input = try XCTUnwrap(window.firstResponder as? NSTextView)
        let prompt = try XCTUnwrap(input.enclosingScrollView?.superview)
        XCTAssertLessThanOrEqual(prompt.frame.maxX, editor.textView.visibleRect.maxX + 1)
        XCTAssertFalse(prompt.isHidden)
        editor.textView.scrollRangeToVisible(NSRange(location: editor.state.text.utf16.count, length: 0))
        editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport(); editor.refreshToolPresentation()
        XCTAssertTrue(prompt.isHidden || !prompt.frame.intersects(editor.textView.visibleRect))
    }
}
