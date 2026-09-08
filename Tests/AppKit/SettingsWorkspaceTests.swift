import XCTest
import AppKit
import JortSettings
import JortPersistence
@testable import JortAppKit

@MainActor final class SettingsWorkspaceTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JortSettingsAppKit-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private var template: ToolTemplate { ToolTemplate(id: ToolID("builtin.sample"), displayName: "Sample", commandName: "sample", source: "return input;") }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out")
    }

    func testWorkspaceSingletonSelectionFallbackAndMinimumSize() async throws {
        _ = NSApplication.shared
        let suite = "SettingsWorkspaceTests-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defaults.set("missing", forKey: "Jort.Settings.SelectedPane")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SQLiteSettingsStore(directory: try root(), templates: [template])
        let tools = ToolsSettingsViewController(store: store, templates: [template])
        let controller = SettingsWindowController(panes: [.init(id: "tools", title: "Tools", symbolName: "hammer") { tools }], defaults: defaults)
        XCTAssertEqual(controller.selectedPaneID, "tools"); XCTAssertEqual(controller.window?.minSize, NSSize(width: 680, height: 480))
        let identity = controller.window; controller.present(); controller.present(); XCTAssertTrue(identity === controller.window)
        try await waitUntil { tools.snapshot.availability == .ready }
        controller.window?.orderOut(nil); try await store.close()
    }

    func testToolsPaneLoadsTemplateCreatesValidatesAndPreservesSourceUndoIsolation() async throws {
        _ = NSApplication.shared
        let store = SQLiteSettingsStore(directory: try root(), templates: [template])
        let pane = ToolsSettingsViewController(store: store, templates: [template]); _ = pane.view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false); window.contentViewController = pane; window.makeKeyAndOrderFront(nil)
        try await waitUntil { pane.tools.count == 1 }
        XCTAssertEqual(pane.tools.first?.origin, .bundledTemplate); XCTAssertFalse(pane.deleteButton.isHidden == false)
        pane.newTool(); pane.nameField.stringValue = "Unicode 🌲"; pane.commandField.stringValue = "tree"; pane.summaryField.stringValue = "Test"; pane.sourceEditor.source = "return '🌲';"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)); pane.sourceEditor.onChange?(pane.sourceEditor.source)
        XCTAssertTrue(pane.hasUnsavedChanges); XCTAssertTrue(pane.saveButton.isEnabled)
        pane.saveDraft(); try await waitUntil { pane.snapshot.customTools.count == 1 }
        XCTAssertEqual(pane.snapshot.customTools.first?.source, "return '🌲';")
        XCTAssertTrue(pane.sourceEditor.textView.undoManager === pane.sourceEditor.textView.sourceUndoManager)
        window.orderOut(nil); try await store.close()
    }

    func testSourceEditorExactTextBoundsStatusAndDiagnosticReveal() {
        _ = NSApplication.shared
        let editor = JavaScriptSourceEditor(); editor.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let source = "const café = '🌲';\nreturn café;"; editor.source = source; XCTAssertEqual(editor.source, source)
        editor.textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0)); editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification)); XCTAssertTrue(editor.status.stringValue.contains("Line 2"))
        editor.reveal(.init(location: 6, length: 4)); XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 6, length: 4))
        XCTAssertFalse(editor.textView.isRichText); XCTAssertFalse(editor.textView.isAutomaticQuoteSubstitutionEnabled); XCTAssertFalse(editor.textView.isContinuousSpellCheckingEnabled)
    }

    func testPocketActionPreservesDocumentAndCallsSharedPresenter() async throws {
        _ = NSApplication.shared
        let root = try root(), editor = EditorViewController(persistence: PersistenceController(directory: root))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled], backing: .buffered, defer: false); window.contentViewController = editor; window.makeKeyAndOrderFront(nil)
        var opened = 0; editor.openSettings = { opened += 1 }; let before = editor.state
        let action = try XCTUnwrap(editor.paletteActions().first(where: { $0.id == "settings.open" })); action.execute()
        XCTAssertEqual(opened, 1); XCTAssertEqual(editor.state, before); window.orderOut(nil)
    }
}
