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
        let outer = try XCTUnwrap(controller.window?.contentViewController as? NSSplitViewController)
        let sidebar = try XCTUnwrap(outer.splitViewItems.first?.viewController as? SettingsSidebarController)
        XCTAssertEqual(sidebar.table.numberOfRows, 1)
        XCTAssertEqual(sidebar.table.view(atColumn: 0, row: 0, makeIfNecessary: true)?.accessibilityLabel(), "Tools")
        let inner = try XCTUnwrap(tools.view.subviews.first as? NSSplitView)
        tools.view.layoutSubtreeIfNeeded()
        let listWidth = inner.arrangedSubviews[0].frame.width
        let editorWidth = inner.arrangedSubviews[1].frame.width
        controller.window?.setContentSize(NSSize(width: 1200, height: 600))
        outer.view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(inner.arrangedSubviews[0].frame.width, listWidth + 10)
        XCTAssertGreaterThan(inner.arrangedSubviews[1].frame.width, editorWidth + 200)
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

    func testNewPackageSavesWithoutLeaveWarningAndIsExecutable() async throws {
        _ = NSApplication.shared
        let directory = try root()
        let registry = ToolPackageRegistry(bundledDirectory: directory.appendingPathComponent("Bundled"), installedDirectory: directory.appendingPathComponent("Tools"))
        let store = PackageSettingsStore(registry: registry, preferences: SQLiteSettingsStore(directory: directory))
        let pane = ToolsSettingsViewController(store: store, templates: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = pane; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await waitUntil { pane.snapshot.availability == .ready }
        pane.newTool()
        XCTAssertEqual(pane.enabledButton.state, .on)
        XCTAssertFalse(pane.enabledButton.isHidden)
        pane.nameField.stringValue = "Echo"; pane.commandField.stringValue = "echo"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        pane.enabledButton.state = .off; pane.toggleEnabled()
        XCTAssertEqual(pane.draft?.definition.isEnabled, false)
        pane.enabledButton.state = .on; pane.toggleEnabled()
        pane.saveDraft()
        try await waitUntil { pane.snapshot.customTools.count == 1 && !pane.hasUnsavedChanges }
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(pane.enabledButton.isHidden)
        XCTAssertTrue(pane.sourceEditor.layer?.masksToBounds == true)
        XCTAssertTrue(pane.sourceEditor.scrollView.verticalRulerView?.layer?.masksToBounds == true)
        pane.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds))
        pane.view.cacheDisplay(in: pane.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/jort-feedback2-settings.png"))
        let catalog = try await registry.inspect()
        let package = try XCTUnwrap(catalog.executable.first { $0.manifest.command == "/echo" })
        let result = await ToolRuntime.execute(package, input: .init(content: "hello"))
        XCTAssertEqual(result.output, "hello")
        let editor = EditorViewController(persistence: PersistenceController(directory: directory.appendingPathComponent("Document")))
        let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        editorWindow.isReleasedWhenClosed = false; editorWindow.contentViewController = editor; editorWindow.makeKeyAndOrderFront(nil)
        defer { editorWindow.orderOut(nil) }
        try await waitUntil { editor.coordinator.onTransaction != nil }
        editor.toolPackages = catalog.executable
        editor.textView.insertText("/", replacementRange: NSRange(location: 0, length: 0))
        editor.textView.insertText("ec", replacementRange: editor.textView.selectedRange())
        editor.view.layoutSubtreeIfNeeded(); editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.refreshToolPresentation()
        let popup = try XCTUnwrap(editor.view.subviews.first { $0.accessibilityLabel() == "Tool completions" })
        let option = try XCTUnwrap(popup.subviews.first as? NSButton)
        XCTAssertTrue(option.accessibilityLabel()?.contains("/echo") == true)
        XCTAssertTrue(option.accessibilityPerformPress())
        XCTAssertEqual(editor.state.text, "/echo ")
        try await store.close()
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
