import XCTest
import AppKit
import SQLite3
@testable import Jort

final class JortCoreTests: XCTestCase {
    func testSplitJoinAndWhitespace() throws {
        var state = DocumentState()
        let first = Date(timeIntervalSince1970: 100)
        state.replaceText("hello world\nsecond", at: first)
        let leading = state.lines[0].id, second = state.lines[1].id
        state.replaceText("hello\n world\nsecond")
        XCTAssertEqual(state.lines[0].id, leading)
        XCTAssertEqual(state.lines[2].id, second)
        XCTAssertEqual(state.lines[0].createdAt, first)
        state.replaceText("hello world\nsecond")
        XCTAssertEqual(state.lines[0].id, leading)
        XCTAssertEqual(state.lines[1].id, second)
        state.replaceText(" \nsecond")
        XCTAssertNil(state.lines[0].createdAt)
        XCTAssertNil(state.lines[0].lastEditedAt)
        try state.validate()
    }
    func testUnicodeAndNewlines() throws {
        for text in ["", "a\n", "🦊 café\n👨‍👩‍👧‍👦\n日本語", "a\r\nb\r\n", "a\rb", "\n\n", "e\u{301}\nend"] {
            var state = DocumentState(); state.replaceText(text)
            try state.validate()
            XCTAssertEqual(state.lines.reduce(0) { $0 + $1.length }, text.utf16.count)
        }
    }
    func testRandomEditsKeepValidUniqueLines() throws {
        var state = DocumentState()
        var seed: UInt64 = 41
        func next(_ count: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int(seed >> 32) % count }
        for _ in 0..<1500 {
            var chars = Array(state.text)
            let start = next(chars.count + 1)
            let length = next(chars.count - start + 1)
            chars.replaceSubrange(start..<(start + length), with: Array(["a", "\n", "🦊", " ", "é", "\r\n"][next(6)]))
            state.replaceText(String(chars)); try state.validate()
        }
    }
    func testSQLiteRoundTripAndRecovery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var state = DocumentState(); state.replaceText("Persist me 🦊\nsecond line")
        do { let store = SQLiteStore(directory: url); try store.save(state); XCTAssertEqual(try store.load(), state) }
        try Data("not a database".utf8).write(to: url.appendingPathComponent("Jort.sqlite"))
        let store = SQLiteStore(directory: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try store.recover(), state)
        XCTAssertEqual(try store.load(), state)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: url.path).contains { $0.hasPrefix("Damaged-") })
    }
    func testNoSafeSnapshotPreservesDamagedStore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let damage = Data("damaged original".utf8)
        try damage.write(to: url.appendingPathComponent("Jort.sqlite"))
        let store = SQLiteStore(directory: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.recover())
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("Jort.sqlite")), damage)
    }
    func testLargeDocumentEdit() throws {
        var state = DocumentState()
        state.replaceText(String(repeating: "A line of notes with a fox 🦊 and something to remember.\n", count: 10000))
        let start = Date()
        state.replaceText(state.text + "done", editRange: NSRange(location: state.text.utf16.count, length: 0), replacementLength: 4)
        try state.validate()
        print("10,000-line reconciliation: \(Date().timeIntervalSince(start))s")
        XCTAssertEqual(state.lines.count, 10001)
    }
    @MainActor
    func testNativeEditingUndoRedoAndPlainText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = PersistenceController(directory: url)
        let controller = EditorViewController(persistence: persistence)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 600, height: 400))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        _ = controller.view
        let loaded = expectation(for: NSPredicate { _, _ in controller.textView.isEditable }, evaluatedWith: nil)
        wait(for: [loaded], timeout: 5)
        window.makeFirstResponder(controller.textView)
        XCTAssertGreaterThan(controller.scroll.frame.width, 300)
        XCTAssertGreaterThan(controller.textView.frame.width, 300)
        XCTAssertGreaterThan(controller.textView.frame.height, 100)
        let text = controller.textView
        XCTAssertNotNil(text.textLayoutManager)
        XCTAssertFalse(text.isRichText)
        let undo = try XCTUnwrap(text.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        text.insertText("hello 🦊\nworld", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        let firstState = controller.state
        undo.beginUndoGrouping()
        text.insertText("\nnew", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        undo.endUndoGrouping()
        let secondState = controller.state
        undo.undo()
        XCTAssertEqual(text.string, firstState.text)
        XCTAssertEqual(controller.state.lines, firstState.lines)
        undo.redo()
        XCTAssertEqual(text.string, secondState.text)
        XCTAssertEqual(controller.state.lines, secondState.lines)
        try controller.state.validate()
        let saved = expectation(description: "Saved native edit")
        persistence.flush { success in XCTAssertTrue(success); saved.fulfill() }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(try SQLiteStore(directory: url).load(), controller.state)
        window.orderOut(nil)
    }

    func testFutureSchemaIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        do { try SQLiteStore(directory: url).save(DocumentState()) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.appendingPathComponent("Jort.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try SQLiteStore(directory: url).load()) { error in
            guard case StoreError.unsupportedVersion = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testIncrementalEditsMatchRangesAndPreserveDistantIdentity() throws {
        var state = DocumentState()
        state.replaceText("first\nsecond\nthird\nlast")
        let last = state.lines.last!
        state.replaceText("fi🦊rst\nsecond\nthird\nlast", editRange: NSRange(location: 2, length: 0), replacementLength: 2)
        XCTAssertEqual(state.lines.last?.id, last.id)
        XCTAssertEqual(state.lines.last?.createdAt, last.createdAt)
        try state.validate()
        state.replaceText("first\nsecond\nthird\nlast")
        var seed: UInt64 = 19
        func next(_ count: Int) -> Int { seed = seed &* 2862933555777941757 &+ 3037000493; return Int(seed >> 32) % count }
        for _ in 0..<1000 {
            let source = state.text as NSString
            let start = next(source.length + 1)
            let end = start + next(source.length - start + 1)
            // ASCII/CRLF fixtures permit all UTF-16 boundaries here.
            let replacement = ["x", "\n", "\r", " ", "\r\n"][next(5)]
            let range = NSRange(location: start, length: end - start)
            let newText = source.replacingCharacters(in: range, with: replacement)
            state.replaceText(newText, editRange: range, replacementLength: replacement.utf16.count)
            try state.validate()
        }
    }

    @MainActor
    func testContinuousTypingSavesWithoutIdle() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = PersistenceController(directory: url)
        let loaded = expectation(description: "Loaded")
        controller.load { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        var document = DocumentState()
        let typed = expectation(description: "Continuous edits")
        var count = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            count += 1
            document.replaceText(document.text + "x")
            controller.changed(document)
            if count == 12 { timer.invalidate(); typed.fulfill() }
        }
        wait(for: [typed], timeout: 4)
        timer.invalidate()
        let persisted = try XCTUnwrap(SQLiteStore(directory: url).load())
        XCTAssertGreaterThan(persisted.text.count, 0)
        XCTAssertLessThanOrEqual(document.text.count - persisted.text.count, 6)
        let flushed = expectation(description: "Flushed")
        controller.flush { saved in XCTAssertTrue(saved); flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
        XCTAssertEqual(try SQLiteStore(directory: url).load(), document)
    }

    @MainActor
    func testMarkedTextIsProvisionalUntilCommit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = PersistenceController(directory: url)
        let controller = EditorViewController(persistence: persistence)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        _ = controller.view
        let loaded = expectation(for: NSPredicate { _, _ in controller.textView.isEditable }, evaluatedWith: nil)
        wait(for: [loaded], timeout: 5)
        window.makeFirstResponder(controller.textView)
        let text = controller.textView
        text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(text.hasMarkedText())
        XCTAssertEqual(controller.state.text, "")
        text.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(controller.state.text, "")
        text.unmarkText()
        XCTAssertEqual(controller.state.text, "日本語")
        try controller.state.validate()
        let saved = expectation(description: "Committed composition saved")
        persistence.flush { success in XCTAssertTrue(success); saved.fulfill() }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(try SQLiteStore(directory: url).load()?.text, "日本語")
        window.orderOut(nil)
    }

    @MainActor
    func testEmptyLinesHaveUniformHeightAndImmediateGutterNumbers() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = EditorViewController(persistence: PersistenceController(directory: url))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 600, height: 400))
        window.makeKeyAndOrderFront(nil)
        let loaded = expectation(for: NSPredicate { _, _ in controller.textView.isEditable }, evaluatedWith: nil)
        wait(for: [loaded], timeout: 5)
        window.makeFirstResponder(controller.textView)
        let text = controller.textView
        text.insertText("asd\na\n\nasd\n", replacementRange: NSRange(location: 0, length: 0))
        text.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let ruler = try XCTUnwrap(controller.scroll.verticalRulerView as? LineRuler)
        let rows = ruler.visibleRows()
        XCTAssertEqual(rows.map(\.number), [1, 2, 3, 4, 5])
        for (before, after) in zip(rows, rows.dropFirst()) {
            XCTAssertEqual(after.y - before.y, 24, accuracy: 0.5)
        }
        text.insertText("\n", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        text.textLayoutManager?.textViewportLayoutController.layoutViewport()
        XCTAssertEqual(ruler.visibleRows().map(\.number), [1, 2, 3, 4, 5, 6])
        window.orderOut(nil)
    }

    @MainActor
    func testWriteFailurePreservesDirtyTextAndStopsRetrying() throws {
        let store = FailingStore()
        let controller = PersistenceController(store: store, retryDelays: [0.01, 0.01, 0.01])
        let loaded = expectation(description: "Loaded")
        controller.load { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        let failures = expectation(description: "Initial write and three retries")
        failures.expectedFulfillmentCount = 4
        controller.onStatus = { _, failed in if failed { failures.fulfill() } }
        var state = DocumentState(); state.replaceText("Keep this text even if the disk fails")
        controller.changed(state)
        controller.flush()
        wait(for: [failures], timeout: 5)
        XCTAssertEqual(store.writeCount, 4)
        XCTAssertEqual(controller.state, state)
        controller.onStatus = nil
        state.replaceText(state.text + "!")
        controller.changed(state)
        let quiet = expectation(description: "No unlimited retries")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { quiet.fulfill() }
        wait(for: [quiet], timeout: 2)
        XCTAssertEqual(store.writeCount, 4)
        store.allowWrites()
        let saved = expectation(description: "Manual retry saves newest text")
        controller.onStatus = { message, failed in
            if !failed && message == "Saved on this Mac" { saved.fulfill() }
        }
        controller.retry()
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(store.savedState, state)
    }

}


private final class FailingStore: DocumentStore {
    private let lock = NSLock()
    private var failing = true
    private var count = 0
    private var saved: DocumentState?
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var savedState: DocumentState? { lock.lock(); defer { lock.unlock() }; return saved }
    func allowWrites() { lock.lock(); failing = false; lock.unlock() }
    func load() throws -> DocumentState? { nil }
    func recover() throws -> DocumentState { throw StoreError.message("Injected corruption") }
    func save(_ state: DocumentState) throws {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if failing { throw StoreError.message("Injected disk failure") }
        saved = state
    }
}
