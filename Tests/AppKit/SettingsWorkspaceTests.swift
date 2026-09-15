import XCTest
import AppKit
import JortSettings
import JortPersistence
@testable import JortAppKit

@MainActor final class SettingsWorkspaceTests: StoreTestCase {
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "JortSettingsAppKit-\(UUID())")
    removeAfterStoresClose(url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private var template: ToolTemplate {
    ToolTemplate(
      id: ToolID("builtin.sample"), displayName: "Sample", commandName: "sample",
      source: "return input;")
  }
  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out")
  }

  func testWorkspaceSingletonSelectionFallbackAndMinimumSize() async throws {
    _ = NSApplication.shared
    let suite = "SettingsWorkspaceTests-\(UUID())",
      defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set("missing", forKey: "Jort.Settings.SelectedPane")
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ownStore(SQLiteSettingsStore(directory: try root(), templates: [template]))
    let tools = ToolsSettingsViewController(store: store, templates: [template])
    let controller = SettingsWindowController(
      panes: [.init(id: "tools", title: "Tools", symbolName: "hammer") { tools }],
      defaults: defaults)
    XCTAssertEqual(controller.selectedPaneID, "tools")
    XCTAssertEqual(controller.window?.minSize, NSSize(width: 680, height: 480))
    let identity = controller.window
    controller.present()
    controller.present()
    XCTAssertTrue(identity === controller.window)
    let outer = try XCTUnwrap(controller.window?.contentViewController as? NSSplitViewController)
    let sidebar = try XCTUnwrap(
      outer.splitViewItems.first?.viewController as? SettingsSidebarController)
    XCTAssertEqual(sidebar.table.numberOfRows, 1)
    XCTAssertEqual(
      sidebar.table.view(atColumn: 0, row: 0, makeIfNecessary: true)?.accessibilityLabel(), "Tools")
    let inner = try XCTUnwrap(tools.view.subviews.first as? NSSplitView)
    tools.view.layoutSubtreeIfNeeded()
    let listWidth = inner.arrangedSubviews[0].frame.width
    let editorWidth = inner.arrangedSubviews[1].frame.width
    controller.window?.setContentSize(NSSize(width: 1200, height: 600))
    outer.view.layoutSubtreeIfNeeded()
    XCTAssertLessThanOrEqual(inner.arrangedSubviews[0].frame.width, listWidth + 10)
    XCTAssertGreaterThan(inner.arrangedSubviews[1].frame.width, editorWidth + 200)
    try await waitUntil { tools.snapshot.availability == .ready }
    controller.window?.orderOut(nil)
    try await store.close()
  }

  func testToolsPaneLoadsTemplateCreatesValidatesAndPreservesSourceUndoIsolation() async throws {
    _ = NSApplication.shared
    let store = ownStore(SQLiteSettingsStore(directory: try root(), templates: [template]))
    let pane = ToolsSettingsViewController(store: store, templates: [template])
    _ = pane.view
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentViewController = pane
    window.makeKeyAndOrderFront(nil)
    try await waitUntil { pane.tools.count == 1 }
    XCTAssertEqual(pane.tools.first?.origin, .bundledTemplate)
    XCTAssertFalse(pane.deleteButton.isHidden == false)
    pane.newTool()
    pane.nameField.stringValue = "Unicode 🌲"
    pane.commandField.stringValue = "tree"
    pane.summaryField.stringValue = "Test"
    pane.sourceEditor.source = "return '🌲';"
    pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    pane.sourceEditor.onChange?(pane.sourceEditor.source)
    XCTAssertTrue(pane.hasUnsavedChanges)
    XCTAssertTrue(pane.saveButton.isEnabled)
    pane.saveDraft()
    try await waitUntil { pane.snapshot.customTools.count == 1 }
    XCTAssertEqual(pane.snapshot.customTools.first?.source, "return '🌲';")
    XCTAssertTrue(
      pane.sourceEditor.textView.undoManager === pane.sourceEditor.textView.sourceUndoManager)
    window.orderOut(nil)
    try await store.close()
  }

  func testSourceEditorExactTextBoundsStatusAndDiagnosticReveal() {
    _ = NSApplication.shared
    let editor = JavaScriptSourceEditor()
    editor.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    let source = "const café = '🌲';\nreturn café;"
    editor.source = source
    XCTAssertEqual(editor.source, source)
    editor.textView.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
    editor.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
    XCTAssertTrue(editor.status.stringValue.contains("Line 2"))
    editor.reveal(.init(location: 6, length: 4))
    XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 6, length: 4))
    XCTAssertFalse(editor.textView.isRichText)
    XCTAssertFalse(editor.textView.isAutomaticQuoteSubstitutionEnabled)
    XCTAssertFalse(editor.textView.isContinuousSpellCheckingEnabled)
  }

  func testNewPackageSavesWithoutLeaveWarningAndIsExecutable() async throws {
    _ = NSApplication.shared
    let directory = try root()
    let registry = ToolPackageRegistry(
      bundledDirectory: directory.appendingPathComponent("Bundled"),
      installedDirectory: directory.appendingPathComponent("Tools"))
    let store = ownStore(
      PackageSettingsStore(
        registry: registry, preferences: ownStore(SQLiteSettingsStore(directory: directory))))
    let pane = ToolsSettingsViewController(store: store, templates: [])
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = pane
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    try await waitUntil { pane.snapshot.availability == .ready }
    pane.newTool()
    XCTAssertEqual(pane.enabledButton.state, .on)
    XCTAssertFalse(pane.enabledButton.isHidden)
    pane.nameField.stringValue = "Echo"
    pane.commandField.stringValue = "echo"
    pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    pane.enabledButton.state = .off
    pane.toggleEnabled()
    XCTAssertEqual(pane.draft?.definition.isEnabled, false)
    pane.enabledButton.state = .on
    pane.toggleEnabled()
    pane.saveDraft()
    try await waitUntil { pane.snapshot.customTools.count == 1 && !pane.hasUnsavedChanges }
    XCTAssertNil(window.attachedSheet)
    XCTAssertFalse(pane.enabledButton.isHidden)
    XCTAssertTrue(pane.sourceEditor.layer?.masksToBounds == true)
    XCTAssertTrue(pane.sourceEditor.scrollView.verticalRulerView?.layer?.masksToBounds == true)
    pane.view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds))
    pane.view.cacheDisplay(in: pane.view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: "/private/tmp/jort-feedback2-settings.png"))
    let catalog = try await registry.inspect()
    let package = try XCTUnwrap(catalog.executable.first { $0.manifest.command == "/echo" })
    let result = await ToolRuntime.execute(package, input: .init(content: "hello"))
    XCTAssertEqual(result.output, "hello")
    let editor = EditorViewController(
      persistence: ownPersistence(directory: directory.appendingPathComponent("Document")))
    let editorWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    editorWindow.isReleasedWhenClosed = false
    editorWindow.contentViewController = editor
    editorWindow.makeKeyAndOrderFront(nil)
    defer { editorWindow.orderOut(nil) }
    try await waitUntil { editor.coordinator.onTransaction != nil }
    editor.toolPackages = catalog.executable
    editor.textView.insertText("/", replacementRange: NSRange(location: 0, length: 0))
    editor.textView.insertText("ec", replacementRange: editor.textView.selectedRange())
    editor.view.layoutSubtreeIfNeeded()
    editor.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    editor.refreshToolPresentation()
    let popup = try XCTUnwrap(
      editor.view.subviews.first { $0.accessibilityLabel() == "Tool completions" })
    let option = try XCTUnwrap(popup.subviews.first as? NSButton)
    XCTAssertTrue(option.accessibilityLabel()?.contains("/echo") == true)
    XCTAssertTrue(option.accessibilityPerformPress())
    XCTAssertEqual(editor.state.text, "/echo ")
    try await store.close()
  }

  func testPocketActionPreservesDocumentAndCallsSharedPresenter() async throws {
    _ = NSApplication.shared
    let root = try root(),
      editor = EditorViewController(persistence: ownPersistence(directory: root))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentViewController = editor
    window.makeKeyAndOrderFront(nil)
    var opened = 0
    editor.openSettings = { opened += 1 }
    let before = editor.state
    let action = try XCTUnwrap(editor.paletteActions().first(where: { $0.id == "settings.open" }))
    action.execute()
    XCTAssertEqual(opened, 1)
    XCTAssertEqual(editor.state, before)
    window.orderOut(nil)
  }
}

extension SettingsWorkspaceTests {
  func testDisconnectedModelAuthoringPickerAndPersistence() async throws {
    _ = NSApplication.shared
    let directory = try root(),
      registry = ToolPackageRegistry(
        bundledDirectory: directory.appendingPathComponent("empty"),
        installedDirectory: directory.appendingPathComponent("tools"))
    let store = ownStore(
      PackageSettingsStore(
        registry: registry, preferences: ownStore(SQLiteSettingsStore(directory: directory))))
    let pane = ToolsSettingsViewController(store: store, templates: [])
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = pane
    try await waitUntil { pane.snapshot.availability == .ready }
    pane.newTool()
    pane.sourceEditor.source = ""
    pane.sourceEditor.onChange?("")
    pane.executorButton.selectItem(withTitle: "model")
    pane.changeExecutor()
    XCTAssertTrue(pane.sourceEditor.isHidden)
    XCTAssertFalse(pane.instructionsEditor.isHidden)
    XCTAssertFalse(pane.saveButton.isEnabled)
    pane.instructionsEditor.source = "Answer clearly."
    pane.instructionsEditor.onChange?("Answer clearly.")
    XCTAssertTrue(pane.saveButton.isEnabled)
    XCTAssertEqual(pane.instructionsEditor.textView.maximumUTF8Bytes, 32_768)
    XCTAssertEqual(pane.instructionsEditor.textView.accessibilityLabel(), "Model instructions")
    pane.saveDraft()
    try await waitUntil { pane.snapshot.customTools.count == 1 }
    XCTAssertEqual(pane.snapshot.customTools.first?.instructions, "Answer clearly.")
    XCTAssertEqual(pane.snapshot.customTools.first?.manifest?.modelID, ModelCatalog.defaultModelID)
    let picker = ModelPicker()
    _ = picker.view
    picker.search.stringValue = "Anthropic"
    picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    XCTAssertEqual(picker.models.count, 1)
    var selected: String?
    picker.onSelect = { selected = $0 }
    picker.selectModel()
    XCTAssertEqual(selected, "anthropic/claude-sonnet-4.6")
    window.setContentSize(NSSize(width: 900, height: 600))
    pane.view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(pane.instructionsEditor.frame.height, 100)
    window.orderOut(nil)
    try await store.close()
  }
  func testModelsPaneLocalNavigationAndAccessibleDisconnectedState() async throws {
    _ = NSApplication.shared
    let connection = OpenRouterConnection(credentials: MemoryModelCredentialStore())
    let models = ModelsSettingsViewController(connection: connection)
    let tools = ToolsSettingsViewController(
      store: ownStore(SQLiteSettingsStore(directory: try root())), templates: [])
    let controller = SettingsWindowController(panes: [
      .init(id: "tools", title: "Tools", symbolName: "hammer") { tools },
      .init(id: "models", title: "Models", symbolName: "sparkles") { models },
    ])
    controller.selectPane(id: "models")
    await models.refresh()
    XCTAssertEqual(controller.selectedPaneID, "models")
    XCTAssertEqual(models.statusLabel.stringValue, "Not Connected")
    XCTAssertEqual(models.connectButton.title, "Connect with OpenRouter")
    XCTAssertTrue(models.checkButton.isHidden)
    XCTAssertTrue(models.disconnectButton.isHidden)
    XCTAssertTrue(models.initialFirstResponder === models.connectButton)
    XCTAssertEqual(models.view.accessibilityLabel(), "Models settings")
    controller.window?.orderOut(nil)
  }
}

private actor SettingsModelTransport: OpenRouterTransport {
  private(set) var count = 0
  var failure: ModelFailure?
  func fail(_ failure: ModelFailure?) { self.failure = failure }
  func send(_ request: URLRequest, maximumBytes: Int) throws -> Data {
    count += 1
    if let failure { throw failure }
    return Data(#"{"data":{"label":"test connection"}}"#.utf8)
  }
}

extension SettingsWorkspaceTests {
  func testModelsConnectionStatesAndNoNetworkWhenOpened() async throws {
    _ = NSApplication.shared
    let transport = SettingsModelTransport(), credentials = MemoryModelCredentialStore("test-only")
    let connection = OpenRouterConnection(credentials: credentials, transport: transport)
    let pane = ModelsSettingsViewController(connection: connection)
    _ = pane.view
    await pane.refresh()
    let unopenedCount = await transport.count
    XCTAssertEqual(unopenedCount, 0)
    try await connection.check()
    await pane.refresh()
    XCTAssertEqual(pane.statusLabel.stringValue, "Connected")
    XCTAssertEqual(pane.connectButton.title, "Replace Connection")
    XCTAssertFalse(pane.disconnectButton.isHidden)
    await transport.fail(.offline)
    do { try await connection.check() } catch {}
    await pane.refresh()
    XCTAssertEqual(pane.statusLabel.stringValue, "Unable to Verify")
    await transport.fail(.authentication)
    do { try await connection.check() } catch {}
    await pane.refresh()
    XCTAssertEqual(pane.statusLabel.stringValue, "Connection Needs Attention")
    try await connection.disconnect()
    await pane.refresh()
    XCTAssertEqual(pane.statusLabel.stringValue, "Not Connected")
    let count = await transport.count
    XCTAssertEqual(count, 3)
  }
  func testExecutorTransitionCancellationPreservesDraftAndLocalUndo() async throws {
    _ = NSApplication.shared
    let pane = ToolsSettingsViewController(
      store: ownStore(SQLiteSettingsStore(directory: try root())), templates: [])
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = pane
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    try await waitUntil { pane.snapshot.availability == .ready }
    pane.newTool()
    let original = pane.draft
    let selection = NSRange(location: 3, length: 4)
    pane.sourceEditor.textView.setSelectedRange(selection)
    pane.executorButton.selectItem(withTitle: "model")
    pane.changeExecutor()
    let sheet = try XCTUnwrap(window.attachedSheet)
    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    try await waitUntil { window.attachedSheet == nil }
    XCTAssertEqual(pane.draft, original)
    XCTAssertEqual(pane.sourceEditor.textView.selectedRange(), selection)
    XCTAssertEqual(pane.executorButton.titleOfSelectedItem, "javascript")
    XCTAssertFalse(pane.sourceEditor.isHidden)
  }
}

private actor ControlledToolValidator: ToolDefinitionValidator {
  private var continuation: CheckedContinuation<[ToolDiagnostic], Never>?
  private var entered: [CheckedContinuation<Void, Never>] = []
  private(set) var count = 0
  func diagnostics(for definition: UserToolDefinition) async -> [ToolDiagnostic] {
    count += 1
    entered.forEach { $0.resume() }
    entered = []
    return await withCheckedContinuation { continuation = $0 }
  }
  func waitForEntry() async {
    if count > 0 { return }
    await withCheckedContinuation { entered.append($0) }
  }
  func finish(_ diagnostics: [ToolDiagnostic] = []) {
    continuation?.resume(returning: diagnostics)
    continuation = nil
  }
}

private actor ControlledToolStore: SettingsStore {
  enum Outcome: Sendable { case success, failure, conflict, uncertain }
  private var value = SettingsSnapshot()
  private var continuation: CheckedContinuation<Void, Never>?
  private var entered: [CheckedContinuation<Void, Never>] = []
  private(set) var count = 0
  let outcome: Outcome
  init(_ outcome: Outcome = .success) { self.outcome = outcome }
  func load() -> SettingsSnapshot { value }
  func currentSnapshot() -> SettingsSnapshot { value }
  func updates() -> AsyncStream<SettingsSnapshot> { AsyncStream { $0.finish() } }
  func setPreference(key: String, value: String?) -> SettingsSnapshot { self.value }
  func setTemplateEnabled(id: ToolID, enabled: Bool?) -> SettingsSnapshot { value }
  func delete(id: ToolID, expectedRevision: RecordRevision) -> SettingsSnapshot { value }
  func close() {}
  func recoveryDirectory() -> URL? { URL(fileURLWithPath: "/private/tmp") }
  func save(_ definition: UserToolDefinition, expectedRevision: RecordRevision?) async throws
    -> SettingsSnapshot
  {
    count += 1
    entered.forEach { $0.resume() }
    entered = []
    await withCheckedContinuation { continuation = $0 }
    switch outcome {
    case .failure: throw SettingsStoreError.unavailable("Test storage failure")
    case .conflict: throw SettingsStoreError.conflict(current: RecordRevision(8))
    case .uncertain: throw ToolPublicationError.uncertain
    case .success:
      var committed = definition
      committed.revision = RecordRevision(1)
      value.customTools = [committed]
      return value
    }
  }
  func waitForEntry() async {
    if count > 0 { return }
    await withCheckedContinuation { entered.append($0) }
  }
  func finish() {
    continuation?.resume()
    continuation = nil
  }
}

extension SettingsWorkspaceTests {
  func testOwnedSaveHasNoTimeoutAndAllTransitionsAwaitOneSubmission() async throws {
    _ = NSApplication.shared
    let store = ControlledToolStore(), validator = ControlledToolValidator()
    let pane = ToolsSettingsViewController(store: store, templates: [], validator: validator)
    let controller = SettingsWindowController(
      panes: [
        .init(id: "tools", title: "Tools", symbolName: "hammer") { pane },
        .init(id: "other", title: "Other", symbolName: "gear") { SettingsPaneViewController() },
      ], defaults: UserDefaults(suiteName: "OwnedSave-\(UUID())")!)
    let window = try XCTUnwrap(controller.window)
    defer { window.orderOut(nil) }
    try await waitUntil { pane.snapshot.availability == .ready }
    pane.newTool()
    let id = pane.draft?.definition.id
    pane.saveDraft()
    await validator.waitForEntry()
    XCTAssertTrue(pane.isSaving)
    XCTAssertTrue(pane.hasUnsavedChanges)
    XCTAssertEqual(pane.savingAccessibilityLabel, "Saving tool")
    XCTAssertFalse(pane.nameField.isEditable)
    XCTAssertFalse(pane.sourceEditor.isSourceEditable)
    XCTAssertFalse(pane.instructionsEditor.isSourceEditable)
    for control: NSControl in [
      pane.newButton, pane.saveButton, pane.discardButton, pane.deleteButton,
      pane.duplicateButton, pane.enabledButton, pane.modelButton, pane.executorButton,
      pane.inputModeButton, pane.outputOperationButton, pane.toolsTable,
    ] {
      XCTAssertFalse(control.isEnabled)
    }
    pane.newTool()
    pane.duplicateTool()
    pane.discardDraft()
    pane.saveDraft()
    XCTAssertEqual(pane.draft?.definition.id, id)
    var completions: [Bool] = []
    pane.resolvePendingChanges(in: window) { completions.append($0) }
    controller.prepareForTermination { completions.append($0) }
    controller.selectPane(id: "other")
    // Deliberately exceeds the removed two-second polling timeout.
    try await Task.sleep(for: .milliseconds(2100))
    XCTAssertTrue(completions.isEmpty)
    XCTAssertEqual(controller.selectedPaneID, "tools")
    await validator.finish()
    await store.waitForEntry()
    pane.saveDraft()
    let validations = await validator.count, saves = await store.count
    XCTAssertEqual(validations, 1)
    XCTAssertEqual(saves, 1)
    XCTAssertTrue(completions.isEmpty)
    await store.finish()
    try await waitUntil { completions.count == 2 && controller.selectedPaneID == "other" }
    XCTAssertEqual(completions, [true, true])
    XCTAssertFalse(pane.isSaving)
    XCTAssertFalse(pane.hasUnsavedChanges)
    XCTAssertEqual(pane.snapshot.customTools.count, 1)
    pane.newTool()
    let newID = pane.draft?.definition.id
    await Task.yield()
    XCTAssertEqual(pane.draft?.definition.id, newID)
    XCTAssertNotEqual(newID, id)
  }

  func testFailedOwnedSavePreservesDraftSelectionUndoAndRejectsTransitions() async throws {
    _ = NSApplication.shared
    for outcome in [ControlledToolStore.Outcome.failure, .conflict, .uncertain] {
      let store = ControlledToolStore(outcome)
      let pane = ToolsSettingsViewController(store: store, templates: [])
      let controller = SettingsWindowController(
        panes: [
          .init(id: "tools", title: "Tools", symbolName: "hammer") { pane },
          .init(id: "other", title: "Other", symbolName: "gear") { SettingsPaneViewController() },
        ], defaults: UserDefaults(suiteName: "FailedSave-\(UUID())")!)
      let window = try XCTUnwrap(controller.window)
      defer { window.orderOut(nil) }
      try await waitUntil { pane.snapshot.availability == .ready }
      pane.newTool()
      let original = pane.draft
      let selection = NSRange(location: 3, length: 4)
      pane.sourceEditor.textView.setSelectedRange(selection)
      let undo = pane.sourceEditor.textView.undoManager
      window.makeFirstResponder(pane.sourceEditor.textView)
      pane.saveDraft()
      await store.waitForEntry()
      var completions: [Bool] = []
      pane.resolvePendingChanges(in: window) { completions.append($0) }
      controller.prepareForTermination { completions.append($0) }
      controller.selectPane(id: "other")
      XCTAssertFalse(controller.windowShouldClose(window))
      await store.finish()
      try await waitUntil { completions.count == 2 && !pane.isSaving }
      XCTAssertEqual(completions, [false, false])
      XCTAssertEqual(controller.selectedPaneID, "tools")
      XCTAssertEqual(pane.draft, original)
      XCTAssertEqual(pane.sourceEditor.textView.selectedRange(), selection)
      XCTAssertTrue(pane.sourceEditor.textView.undoManager === undo)
      XCTAssertTrue(window.firstResponder === pane.sourceEditor.textView)
      XCTAssertTrue(pane.sourceEditor.isSourceEditable)
      XCTAssertTrue(pane.saveButton.isEnabled)
      if case .uncertain = outcome { XCTAssertTrue(pane.canShowRecoveryFiles) }
      let count = await store.count
      XCTAssertEqual(count, 1)
    }
  }

  func testBlockingInjectedValidationNeverSubmitsToStore() async throws {
    let store = ControlledToolStore(), validator = ControlledToolValidator()
    let pane = ToolsSettingsViewController(store: store, templates: [], validator: validator)
    _ = pane.view
    try await waitUntil { pane.snapshot.availability == .ready }
    pane.newTool()
    let before = pane.draft
    let waiter = Task { await pane.awaitSave() }
    await validator.waitForEntry()
    await validator.finish([
      ToolDiagnostic(severity: .error, field: .source, message: "Blocked by validator")
    ])
    let result = await waiter.value
    XCTAssertFalse(result.succeeded)
    XCTAssertEqual(pane.draft, before)
    XCTAssertFalse(pane.isSaving)
    XCTAssertFalse(pane.saveButton.isEnabled)
    let count = await store.count
    XCTAssertEqual(count, 0)
  }
}

extension SettingsWorkspaceTests {
  func testSaveDiscardCancelSheetResolutionAndSuccessfulClose() async throws {
    _ = NSApplication.shared
    let store = ControlledToolStore(), validator = ControlledToolValidator()
    let pane = ToolsSettingsViewController(store: store, templates: [], validator: validator)
    let controller = SettingsWindowController(panes: [
      .init(id: "tools", title: "Tools", symbolName: "hammer") { pane }
    ])
    let window = try XCTUnwrap(controller.window)
    defer { window.orderOut(nil) }
    window.makeKeyAndOrderFront(nil)
    try await waitUntil { pane.snapshot.availability == .ready }
    pane.newTool()
    let original = pane.draft
    var outcomes: [Bool] = []
    pane.resolvePendingChanges(in: window) { outcomes.append($0) }
    window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertThirdButtonReturn)
    try await waitUntil { outcomes.count == 1 }
    XCTAssertEqual(outcomes, [false])
    XCTAssertEqual(pane.draft, original)
    pane.resolvePendingChanges(in: window) { outcomes.append($0) }
    window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
    try await waitUntil { outcomes.count == 2 }
    XCTAssertEqual(outcomes, [false, true])
    XCTAssertFalse(pane.hasUnsavedChanges)
    pane.newTool()
    XCTAssertFalse(controller.windowShouldClose(window))
    window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
    await validator.waitForEntry()
    XCTAssertTrue(window.isVisible)
    await validator.finish()
    await store.waitForEntry()
    XCTAssertTrue(window.isVisible)
    await store.finish()
    try await waitUntil { !pane.isSaving && !window.isVisible }
    XCTAssertFalse(pane.hasUnsavedChanges)
    let saves = await store.count
    XCTAssertEqual(saves, 1)
  }
}
