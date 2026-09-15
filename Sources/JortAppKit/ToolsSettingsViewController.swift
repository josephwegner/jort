import JortToolContracts
import AppKit
import JortSettings

struct ToolDraftSubmission: Sendable {
  let definition: UserToolDefinition
  let baseRevision: RecordRevision?
}

enum ToolDraftSaveResult: Sendable {
  case success(SettingsSnapshot)
  case diagnostics([ToolDiagnostic])
  case conflict(RecordRevision?)
  case storageFailure(String)
  case publicationUncertain
  case cancelled
  var succeeded: Bool {
    if case .success = self { return true }
    return false
  }
}

@MainActor
public final class ToolsSettingsViewController: SettingsPaneViewController, NSTableViewDataSource,
  NSTableViewDelegate, NSTextFieldDelegate
{
  let store: any SettingsStore
  let templates: [ToolTemplate]
  let validator: any ToolDefinitionValidator
  let toolsTable = NSTableView(), diagnosticsTable = NSTableView()
  let nameField = NSTextField(), commandField = NSTextField(), summaryField = NSTextField()
  let inputModeButton = NSPopUpButton(), outputOperationButton = NSPopUpButton()
  let sourceEditor = JavaScriptSourceEditor()
  let instructionsEditor = JavaScriptSourceEditor()
  let executorButton = NSPopUpButton()
  let modelButton = NSButton(title: "Choose model", target: nil, action: nil)
  private let recoveryButton = NSButton(title: "Show Recovery Files", target: nil, action: nil)
  private var recoveryURL: URL?
  private var saveTask: Task<ToolDraftSaveResult, Never>?
  private var saveToken: UUID?
  private var catalogMutation = false
  var isSaving: Bool { saveTask != nil }
  private var isBusy: Bool { isSaving || catalogMutation }
  var savingAccessibilityLabel: String? { saveButton.accessibilityLabel() }
  var canShowRecoveryFiles: Bool { recoveryURL != nil && !recoveryButton.isHidden }
  private let implementationLabel = NSTextField(labelWithString: "JavaScript Source")
  private var modelPopover: NSPopover?
  let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
  let newButton = NSButton(title: "New Tool", target: nil, action: nil)
  let duplicateButton = NSButton(title: "Duplicate to Customize", target: nil, action: nil)
  let saveButton = NSButton(title: "Save", target: nil, action: nil)
  let discardButton = NSButton(title: "Discard", target: nil, action: nil)
  let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
  let retryButton = NSButton(title: "Retry", target: nil, action: nil)
  let status = NSTextField(wrappingLabelWithString: "Loading tools…")
  public private(set) var snapshot = SettingsSnapshot(availability: .loading)
  public private(set) var tools: [ConfiguredTool] = []
  public private(set) var draft: ToolDraft?
  public private(set) var diagnostics: [ToolDiagnostic] = []
  private let builder = ToolCatalogBuilder()
  private var loadTask: Task<Void, Never>?
  private var selectionBeforeChange = -1
  private var updatingFields = false

  public override var hasUnsavedChanges: Bool {
    isSaving || draft?.isDirty == true || (draft != nil && draft?.original == nil)
  }
  public override var initialFirstResponder: NSResponder? { toolsTable }

  public init(
    store: any SettingsStore, templates: [ToolTemplate],
    validator: any ToolDefinitionValidator = StructuralToolValidator()
  ) {
    self.store = store
    self.templates = templates
    self.validator = validator
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  deinit { loadTask?.cancel() }

  public override func loadView() {
    let root = NSView(), split = NSSplitView()
    split.isVertical = true
    split.dividerStyle = .thin
    split.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(split)
    let master = NSView(), detail = NSView()
    split.addArrangedSubview(master)
    split.addArrangedSubview(detail)
    split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
    split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
    let preferredWidth = master.widthAnchor.constraint(equalToConstant: 240)
    preferredWidth.priority = .defaultLow
    preferredWidth.isActive = true
    master.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
    let toolsScroll = NSScrollView()
    toolsScroll.hasVerticalScroller = true
    toolsScroll.documentView = toolsTable
    toolsScroll.translatesAutoresizingMaskIntoConstraints = false
    newButton.translatesAutoresizingMaskIntoConstraints = false
    master.addSubview(toolsScroll)
    master.addSubview(newButton)
    let toolColumn = NSTableColumn(identifier: .init("tools"))
    toolsTable.addTableColumn(toolColumn)
    toolsTable.headerView = nil
    toolsTable.rowHeight = 40
    toolsTable.delegate = self
    toolsTable.dataSource = self
    toolsTable.setAccessibilityLabel("Tools")
    newButton.target = self
    newButton.action = #selector(newTool)
    newButton.identifier = .init("settings.newTool")
    NSLayoutConstraint.activate([
      newButton.leadingAnchor.constraint(equalTo: master.leadingAnchor, constant: 12),
      newButton.trailingAnchor.constraint(equalTo: master.trailingAnchor, constant: -12),
      newButton.bottomAnchor.constraint(equalTo: master.bottomAnchor, constant: -12),
      toolsScroll.leadingAnchor.constraint(equalTo: master.leadingAnchor),
      toolsScroll.trailingAnchor.constraint(equalTo: master.trailingAnchor),
      toolsScroll.topAnchor.constraint(equalTo: master.topAnchor),
      toolsScroll.bottomAnchor.constraint(equalTo: newButton.topAnchor, constant: -8),
    ])
    configureDetail(in: detail)
    NSLayoutConstraint.activate([
      split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      split.topAnchor.constraint(equalTo: root.topAnchor),
      split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    root.setAccessibilityLabel("Tools settings")
    view = root
    loadTask = Task { [weak self] in await self?.reload() }
  }

  private func configureDetail(in detail: NSView) {
    let title = NSTextField(labelWithString: "Tools"), sourceLabel = implementationLabel
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    status.textColor = .secondaryLabelColor
    enabledButton.target = self
    enabledButton.action = #selector(toggleEnabled)
    duplicateButton.target = self
    duplicateButton.action = #selector(duplicateTool)
    saveButton.target = self
    saveButton.action = #selector(saveDraft)
    saveButton.keyEquivalent = "\r"
    discardButton.target = self
    discardButton.action = #selector(discardDraft)
    deleteButton.target = self
    deleteButton.action = #selector(deleteTool)
    retryButton.target = self
    retryButton.action = #selector(retryLoad)
    retryButton.isHidden = true
    recoveryButton.target = self
    recoveryButton.action = #selector(showRecoveryFiles)
    recoveryButton.isHidden = true
    recoveryButton.setAccessibilityLabel("Show tool recovery files in Finder")
    nameField.placeholderString = "Display name"
    commandField.placeholderString = "command-name"
    summaryField.placeholderString = "Description"
    nameField.setAccessibilityLabel("Tool name")
    commandField.setAccessibilityLabel("Command name")
    summaryField.setAccessibilityLabel("Tool description")
    nameField.identifier = .init("settings.toolName")
    commandField.identifier = .init("settings.commandName")
    summaryField.identifier = .init("settings.toolDescription")
    nameField.delegate = self
    commandField.delegate = self
    summaryField.delegate = self
    sourceEditor.onChange = { [weak self] source in self?.updateDraft { $0.source = source } }
    sourceEditor.onOversize = { [weak self] in
      self?.status.stringValue = "JavaScript source cannot exceed 256 KiB."
    }
    instructionsEditor.textView.maximumUTF8Bytes = 32_768
    instructionsEditor.textView.setAccessibilityLabel("Model instructions")
    instructionsEditor.textView.setAccessibilityHelp(
      "Instructions sent with the tool input. Saving does not run the model.")
    instructionsEditor.scrollView.rulersVisible = false
    instructionsEditor.textView.font = .systemFont(ofSize: 13)
    instructionsEditor.onChange = { [weak self] text in self?.updateDraft { $0.instructions = text }
    }
    instructionsEditor.onOversize = { [weak self] in
      self?.status.stringValue = "Instructions cannot exceed 32 KiB."
    }
    executorButton.addItems(withTitles: ToolExecutor.allCases.map(\.rawValue))
    executorButton.setAccessibilityLabel("Executor")
    executorButton.target = self
    executorButton.action = #selector(changeExecutor)
    modelButton.target = self
    modelButton.action = #selector(chooseModel)
    modelButton.setAccessibilityLabel("Selected model")
    let diagnosticScroll = NSScrollView()
    diagnosticScroll.hasVerticalScroller = true
    diagnosticScroll.documentView = diagnosticsTable
    let diagnosticColumn = NSTableColumn(identifier: .init("diagnostic"))
    diagnosticsTable.addTableColumn(diagnosticColumn)
    diagnosticsTable.headerView = nil
    diagnosticsTable.rowHeight = 24
    diagnosticsTable.delegate = self
    diagnosticsTable.dataSource = self
    diagnosticsTable.setAccessibilityLabel("Validation diagnostics")
    diagnosticsTable.target = self
    diagnosticsTable.doubleAction = #selector(revealDiagnostic)
    inputModeButton.addItems(withTitles: ToolInputMode.allCases.map(\.rawValue))
    outputOperationButton.addItems(withTitles: ToolOutputOperation.allCases.map(\.rawValue))
    inputModeButton.setAccessibilityLabel("Input mode")
    outputOperationButton.setAccessibilityLabel("Output operation")
    inputModeButton.target = self
    inputModeButton.action = #selector(changeContract)
    outputOperationButton.target = self
    outputOperationButton.action = #selector(changeContract)
    let contract = NSStackView(views: [inputModeButton, outputOperationButton])
    contract.orientation = .horizontal
    let buttons = NSStackView(views: [
      duplicateButton, deleteButton, retryButton, recoveryButton, NSView(), discardButton,
      saveButton,
    ])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    for item in [
      title, enabledButton, status, nameField, commandField, summaryField, sourceLabel,
      sourceEditor, diagnosticScroll, buttons,
    ] {
      item.translatesAutoresizingMaskIntoConstraints = false
      detail.addSubview(item)
    }
    contract.translatesAutoresizingMaskIntoConstraints = false
    detail.addSubview(contract)
    let implementationRow = NSStackView(views: [executorButton, modelButton])
    implementationRow.orientation = .horizontal
    implementationRow.translatesAutoresizingMaskIntoConstraints = false
    detail.addSubview(implementationRow)
    instructionsEditor.translatesAutoresizingMaskIntoConstraints = false
    detail.addSubview(instructionsEditor)
    NSLayoutConstraint.activate([
      implementationRow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      implementationRow.topAnchor.constraint(equalTo: contract.bottomAnchor, constant: 8),
      implementationRow.trailingAnchor.constraint(lessThanOrEqualTo: status.trailingAnchor),
      instructionsEditor.leadingAnchor.constraint(equalTo: sourceEditor.leadingAnchor),
      instructionsEditor.trailingAnchor.constraint(equalTo: sourceEditor.trailingAnchor),
      instructionsEditor.topAnchor.constraint(equalTo: sourceEditor.topAnchor),
      instructionsEditor.bottomAnchor.constraint(equalTo: sourceEditor.bottomAnchor),
    ])
    sourceEditor.setAccessibilityIdentifier("settings.sourceEditor")
    saveButton.identifier = .init("settings.saveTool")
    NSLayoutConstraint.activate([
      title.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 20),
      title.topAnchor.constraint(equalTo: detail.topAnchor, constant: 18),
      enabledButton.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -20),
      enabledButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      status.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -20),
      status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
      nameField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      nameField.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 14),
      nameField.widthAnchor.constraint(equalTo: detail.widthAnchor, multiplier: 0.45),
      commandField.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 10),
      commandField.trailingAnchor.constraint(equalTo: status.trailingAnchor),
      commandField.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
      summaryField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      summaryField.trailingAnchor.constraint(equalTo: status.trailingAnchor),
      summaryField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 8),
      contract.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      contract.topAnchor.constraint(equalTo: summaryField.bottomAnchor, constant: 8),
      sourceLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      sourceLabel.topAnchor.constraint(equalTo: implementationRow.bottomAnchor, constant: 8),
      sourceEditor.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      sourceEditor.trailingAnchor.constraint(equalTo: status.trailingAnchor),
      sourceEditor.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 6),
      sourceEditor.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
      diagnosticScroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      diagnosticScroll.trailingAnchor.constraint(equalTo: status.trailingAnchor),
      diagnosticScroll.topAnchor.constraint(equalTo: sourceEditor.bottomAnchor, constant: 8),
      diagnosticScroll.heightAnchor.constraint(equalToConstant: 72),
      buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      buttons.trailingAnchor.constraint(equalTo: status.trailingAnchor),
      buttons.topAnchor.constraint(equalTo: diagnosticScroll.bottomAnchor, constant: 8),
      buttons.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -14),
    ])
    showEmptyState()
  }

  public func reload() async {
    guard !isBusy else { return }
    newButton.isEnabled = false
    recoveryURL = await store.recoveryDirectory()
    do {
      let loaded = try await store.load()
      guard !isBusy, !hasUnsavedChanges else { return }
      snapshot = loaded
      retryButton.isHidden = true
      newButton.isEnabled = true
      rebuild()
      status.stringValue =
        snapshot.maintenanceDiagnostics.first
        ?? (tools.isEmpty ? "No tools are configured." : "Saving a tool does not run it.")
      recoveryButton.isHidden = recoveryURL == nil || snapshot.maintenanceDiagnostics.isEmpty
    } catch {
      guard !isBusy, !hasUnsavedChanges else { return }
      snapshot = await store.currentSnapshot()
      retryButton.isHidden = false
      newButton.isEnabled = false
      rebuild()
      status.stringValue = availabilityMessage
      recoveryButton.isHidden = recoveryURL == nil
    }
  }
  @objc private func showRecoveryFiles() {
    guard let recoveryURL else { return }
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: recoveryURL.path)
  }
  private var availabilityMessage: String {
    if case .unavailable(let message) = snapshot.availability { return message }
    return "Settings are unavailable."
  }
  private func rebuild(select id: ToolID? = nil) {
    updatingFields = true
    defer {
      updatingFields = false
      selectionBeforeChange = toolsTable.selectedRow
    }
    tools = builder.configuredTools(templates: templates, snapshot: snapshot)
    toolsTable.reloadData()
    if let id, let index = tools.firstIndex(where: { $0.id == id }) {
      toolsTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      present(tool: tools[index])
    } else if tools.indices.contains(toolsTable.selectedRow) {
      present(tool: tools[toolsTable.selectedRow])
    } else if let first = tools.first {
      toolsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      present(tool: first)
    } else {
      showEmptyState()
    }
  }
  public func numberOfRows(in tableView: NSTableView) -> Int {
    tableView === toolsTable ? tools.count : diagnostics.count
  }
  public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
    -> NSView?
  {
    if tableView === diagnosticsTable {
      let diagnostic = diagnostics[row],
        label = NSTextField(
          labelWithString: "\(diagnostic.severity.rawValue.capitalized): \(diagnostic.message)")
      label.textColor = diagnostic.isBlocking ? .systemRed : .secondaryLabelColor
      label.setAccessibilityLabel(label.stringValue)
      return label
    }
    let tool = tools[row], cell = NSTableCellView(),
      label = NSTextField(labelWithString: tool.displayName),
      detail = NSTextField(
        labelWithString:
          "/\(tool.commandName) · \(tool.origin == .bundledTemplate ? "Template" : "Custom") · \(tool.isEnabled ? "Enabled" : "Disabled")"
      )
    detail.font = .systemFont(ofSize: 10)
    detail.textColor = .secondaryLabelColor
    for item in [label, detail] {
      item.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(item)
    }
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
      label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
      detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
      detail.trailingAnchor.constraint(equalTo: label.trailingAnchor),
      detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
    ])
    cell.setAccessibilityLabel("\(label.stringValue), \(detail.stringValue)")
    return cell
  }
  public func tableViewSelectionDidChange(_ notification: Notification) {
    guard !updatingFields, !isBusy else { return }
    guard tools.indices.contains(toolsTable.selectedRow),
      toolsTable.selectedRow != selectionBeforeChange
    else { return }
    let target = toolsTable.selectedRow
    let targetID = tools[target].id
    if hasUnsavedChanges, let window = view.window {
      let old = selectionBeforeChange
      toolsTable.selectRowIndexes(
        old >= 0 ? IndexSet(integer: old) : [], byExtendingSelection: false)
      resolvePendingChanges(in: window) { [weak self] allowed in
        guard allowed, let self, let target = self.tools.firstIndex(where: { $0.id == targetID })
        else { return }
        self.updatingFields = true
        self.toolsTable.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        self.selectionBeforeChange = target
        self.present(tool: self.tools[target])
      }
    } else {
      selectionBeforeChange = target
      present(tool: tools[target])
    }
  }
  private func present(tool: ConfiguredTool) {
    updatingFields = true
    draft = nil
    diagnostics = tool.diagnostics
    nameField.stringValue = tool.displayName
    commandField.stringValue = tool.commandName
    summaryField.stringValue = tool.summary
    sourceEditor.source = tool.source
    enabledButton.state = tool.isEnabled ? .on : .off
    enabledButton.isHidden = false
    let custom = tool.origin == .custom
    nameField.isEditable = custom
    commandField.isEditable = custom
    summaryField.isEditable = custom
    sourceEditor.isSourceEditable = custom
    let manifest =
      snapshot.customTools.first(where: { $0.id == tool.id })?.manifest
      ?? templates.first(where: { $0.id == tool.id })?.manifest
    duplicateButton.title = manifest == nil ? "Duplicate to Customize" : "Customize"
    inputModeButton.selectItem(withTitle: (manifest?.inputMode ?? .contained).rawValue)
    outputOperationButton.selectItem(
      withTitle: (manifest?.outputOperation ?? .replaceInvocation).rawValue)
    inputModeButton.isEnabled = custom
    outputOperationButton.isEnabled = custom
    duplicateButton.isHidden = custom
    deleteButton.isHidden = !custom
    saveButton.isHidden = !custom
    discardButton.isHidden = !custom
    if custom, let definition = snapshot.customTools.first(where: { $0.id == tool.id }) {
      draft = ToolDraft(
        definition: definition, baseRevision: definition.revision, original: definition)
    }
    let instructions =
      snapshot.customTools.first(where: { $0.id == tool.id })?.instructions
      ?? templates.first(where: { $0.id == tool.id })?.instructions
    showImplementation(manifest: manifest, instructions: instructions, editable: custom)
    diagnosticsTable.reloadData()
    updatingFields = false
    refreshButtons()
  }
  private func showEmptyState() {
    updatingFields = true
    draft = nil
    diagnostics = []
    nameField.stringValue = ""
    commandField.stringValue = ""
    summaryField.stringValue = ""
    sourceEditor.source = ""
    sourceEditor.isSourceEditable = false
    showImplementation(manifest: nil, instructions: nil, editable: false)
    [enabledButton, duplicateButton, deleteButton, saveButton, discardButton].forEach {
      $0.isHidden = true
    }
    diagnosticsTable.reloadData()
    updatingFields = false
  }
  public func controlTextDidChange(_ obj: Notification) {
    guard !updatingFields, !isBusy else { return }
    updateDraft {
      $0.displayName = nameField.stringValue
      $0.commandName = commandField.stringValue
      $0.summary = summaryField.stringValue
    }
  }
  private func showImplementation(manifest: ToolManifest?, instructions: String?, editable: Bool) {
    let model = manifest?.executorType == .model
    executorButton.selectItem(withTitle: (manifest?.executorType ?? .javascript).rawValue)
    executorButton.isEnabled = editable
    sourceEditor.isHidden = model
    instructionsEditor.isHidden = !model
    instructionsEditor.source = instructions ?? ""
    instructionsEditor.isSourceEditable = editable
    modelButton.isHidden = !model
    modelButton.isEnabled = editable
    modelButton.title =
      ModelCatalog.bundled.model(id: manifest?.modelID ?? "")?.name ?? "Unavailable — choose model"
    implementationLabel.stringValue = model ? "Instructions" : "JavaScript Source"
  }
  @objc public func chooseModel() {
    guard !isBusy, draft != nil else { return }
    let picker = ModelPicker(), popover = NSPopover()
    popover.behavior = .transient
    picker.onSelect = { [weak self, weak popover] id in
      guard let self, !self.isBusy else { return }
      self.updateDraft { $0.manifest?.modelID = id }
      self.modelButton.title = ModelCatalog.bundled.model(id: id)?.name ?? id
      popover?.close()
    }
    popover.contentViewController = picker
    modelPopover = popover
    popover.show(relativeTo: modelButton.bounds, of: modelButton, preferredEdge: .maxY)
    picker.view.window?.makeFirstResponder(picker.search)
  }
  @objc public func changeExecutor() {
    guard !isBusy, let draft,
      let type = ToolExecutor(rawValue: executorButton.titleOfSelectedItem ?? ""),
      type != (draft.definition.manifest?.executorType ?? .javascript)
    else { return }
    executorButton.selectItem(
      withTitle: (draft.definition.manifest?.executorType ?? .javascript).rawValue)
    let apply = { [weak self] in
      guard let self, !self.isBusy else { return }
      self.updateDraft {
        var manifest =
          $0.manifest
          ?? ToolManifest(id: $0.id.rawValue, name: $0.displayName, command: "/" + $0.commandName)
        manifest.schemaVersion = 2
        manifest.executor = type
        manifest.modelID = type == .model ? ModelCatalog.defaultModelID : nil
        $0.manifest = manifest
        $0.source = ""
        $0.instructions = type == .model ? "" : nil
      }
      self.sourceEditor.source = ""
      self.showImplementation(
        manifest: self.draft?.definition.manifest,
        instructions: self.draft?.definition.instructions, editable: true)
    }
    let hasContent =
      !draft.definition.source.isEmpty || !(draft.definition.instructions ?? "").isEmpty
    if hasContent {
      guard let window = view.window else { return }
      let alert = NSAlert()
      alert.messageText = "Change executor?"
      alert.informativeText =
        "This discards the current implementation. Common tool settings are kept."
      alert.addButton(withTitle: "Change Executor")
      alert.addButton(withTitle: "Cancel")
      alert.beginSheetModal(for: window) { response in
        if response == .alertFirstButtonReturn { apply() }
      }
    } else {
      apply()
    }
  }
  @objc private func changeContract(_ sender: NSPopUpButton) {
    updateDraft {
      var manifest =
        $0.manifest
        ?? ToolManifest(id: $0.id.rawValue, name: $0.displayName, command: "/" + $0.commandName)
      manifest.inputMode =
        ToolInputMode(rawValue: inputModeButton.titleOfSelectedItem ?? "") ?? .contained
      if sender === inputModeButton {
        outputOperationButton.selectItem(withTitle: manifest.inputMode.defaultOperation.rawValue)
      }
      manifest.outputOperation =
        ToolOutputOperation(rawValue: outputOperationButton.titleOfSelectedItem ?? "")
        ?? manifest.inputMode.defaultOperation
      $0.manifest = manifest
    }
  }
  private func updateDraft(_ body: (inout UserToolDefinition) -> Void) {
    guard !updatingFields, !isBusy, var draft else { return }
    body(&draft.definition)
    self.draft = draft
    validateDraft()
    refreshButtons()
  }
  private func validateDraft() {
    guard let draft else {
      diagnostics = []
      diagnosticsTable.reloadData()
      return
    }
    let occupied = Set(tools.filter { $0.id != draft.definition.id }.map(\.commandName))
    diagnostics = SettingsValidation.diagnostics(for: draft.definition, occupiedNames: occupied)
    diagnosticsTable.reloadData()
  }
  private func refreshButtons() {
    saveButton.isEnabled =
      !isBusy && hasUnsavedChanges && !diagnostics.contains(where: \.isBlocking)
    discardButton.isEnabled = !isBusy && hasUnsavedChanges
  }
  @objc public func newTool() {
    guard !isBusy else { return }
    begin(builder.newDraft(avoiding: Set(tools.map(\.commandName))))
  }
  @objc public func retryLoad() {
    guard !isBusy else { return }
    loadTask?.cancel()
    loadTask = Task { [weak self] in await self?.reload() }
  }
  @objc public func duplicateTool() {
    guard !isBusy else { return }
    guard tools.indices.contains(toolsTable.selectedRow),
      let template = templates.first(where: { $0.id == tools[toolsTable.selectedRow].id })
    else { return }
    if let manifest = template.manifest {
      var definition = UserToolDefinition(
        id: template.id, basedOnTemplateID: template.id,
        displayName: template.displayName, commandName: template.commandName,
        summary: template.summary,
        source: template.source, isEnabled: tools[toolsTable.selectedRow].isEnabled)
      definition.manifest = manifest
      definition.instructions = template.instructions
      begin(ToolDraft(definition: definition))
    } else {
      begin(builder.duplicate(template, avoiding: Set(tools.map(\.commandName))))
    }
  }
  private func begin(_ draft: ToolDraft) {
    if hasUnsavedChanges, let window = view.window {
      resolvePendingChanges(in: window) { [weak self] allowed in if allowed { self?.begin(draft) } }
      return
    }
    self.draft = draft
    updatingFields = true
    nameField.stringValue = draft.definition.displayName
    commandField.stringValue = draft.definition.commandName
    summaryField.stringValue = draft.definition.summary
    sourceEditor.source = draft.definition.source
    sourceEditor.isSourceEditable = true
    enabledButton.isHidden = false
    inputModeButton.isEnabled = true
    outputOperationButton.isEnabled = true
    inputModeButton.selectItem(
      withTitle: (draft.definition.manifest?.inputMode ?? .contained).rawValue)
    outputOperationButton.selectItem(
      withTitle: (draft.definition.manifest?.outputOperation ?? .replaceInvocation).rawValue)
    nameField.isEditable = true
    commandField.isEditable = true
    summaryField.isEditable = true
    enabledButton.state = draft.definition.isEnabled ? .on : .off
    duplicateButton.isHidden = true
    deleteButton.isHidden = draft.original == nil
    saveButton.isHidden = false
    discardButton.isHidden = false
    updatingFields = false
    showImplementation(
      manifest: draft.definition.manifest, instructions: draft.definition.instructions,
      editable: true)
    validateDraft()
    refreshButtons()
    view.window?.makeFirstResponder(nameField)
  }
  @objc public func saveDraft() { _ = startSave() }

  func awaitSave() async -> ToolDraftSaveResult { await startSave().value }

  private func startSave() -> Task<ToolDraftSaveResult, Never> {
    if let saveTask { return saveTask }
    guard !catalogMutation, var draft else { return Task { .cancelled } }
    draft.definition.displayName = nameField.stringValue
    draft.definition.commandName = commandField.stringValue
    draft.definition.summary = summaryField.stringValue
    draft.definition.source = sourceEditor.source
    if draft.definition.manifest?.executorType == .model {
      draft.definition.instructions = instructionsEditor.source
    }
    self.draft = draft
    let submission = ToolDraftSubmission(
      definition: draft.definition, baseRevision: draft.baseRevision)
    let token = UUID()
    saveToken = token
    let focus = view.window?.firstResponder
    let task = Task { [self] in
      let structural = SettingsValidation.diagnostics(
        for: submission.definition,
        occupiedNames: Set(tools.filter { $0.id != submission.definition.id }.map(\.commandName)))
      let injected = await validator.diagnostics(for: submission.definition)
      let allDiagnostics = structural + injected
      let result: ToolDraftSaveResult
      if Task.isCancelled {
        result = .cancelled
      } else if allDiagnostics.contains(where: \.isBlocking) {
        result = .diagnostics(allDiagnostics)
      } else {
        // Cancellation is no longer consulted once storage publication begins.
        do {
          result = .success(
            try await store.save(submission.definition, expectedRevision: submission.baseRevision))
        } catch SettingsStoreError.conflict(let current) {
          result = .conflict(current)
        } catch ToolPackageError.conflict { result = .conflict(nil) } catch ToolPublicationError
          .uncertain
        { result = .publicationUncertain } catch {
          result = .storageFailure(error.localizedDescription)
        }
      }
      finalize(result, submission: submission, token: token, focus: focus)
      return result
    }
    saveTask = task
    setSavingControls(true)
    return task
  }

  private func setSavingControls(_ saving: Bool) {
    modelPopover?.close()
    for control in [nameField, commandField, summaryField] {
      control.isEditable = !saving && draft != nil
    }
    sourceEditor.isSourceEditable = !saving && draft != nil
    instructionsEditor.isSourceEditable = !saving && draft != nil
    for control: NSControl in [
      inputModeButton, outputOperationButton, executorButton, modelButton,
      enabledButton, newButton, duplicateButton, deleteButton, retryButton,
    ] {
      control.isEnabled = !saving
    }
    for control: NSControl in [inputModeButton, outputOperationButton, executorButton, modelButton]
    {
      control.isEnabled = !saving && draft != nil
    }
    toolsTable.isEnabled = !saving
    saveButton.title = saving ? "Saving…" : "Save"
    saveButton.setAccessibilityLabel(saving ? "Saving tool" : "Save tool")
    if saving { status.stringValue = "Saving tool…" }
    refreshButtons()
  }

  private func finalize(
    _ result: ToolDraftSaveResult, submission: ToolDraftSubmission,
    token: UUID, focus: NSResponder?
  ) {
    guard saveToken == token else { return }
    saveToken = nil
    saveTask = nil
    setSavingControls(false)
    switch result {
    case .success(let committed):
      guard draft?.definition.id == submission.definition.id,
        draft?.baseRevision == submission.baseRevision
      else { return }
      snapshot = committed
      draft = nil
      rebuild(select: submission.definition.id)
      status.stringValue =
        committed.maintenanceDiagnostics.first ?? "Tool saved. Saving does not run it."
      recoveryButton.isHidden = recoveryURL == nil || committed.maintenanceDiagnostics.isEmpty
      view.window?.makeFirstResponder(nameField)
    case .diagnostics(let values):
      diagnostics = values
      diagnosticsTable.reloadData()
      status.stringValue = "Fix validation errors before saving."
    case .conflict:
      status.stringValue = "This tool changed while you were editing. Your draft was kept."
    case .storageFailure(let message): status.stringValue = "Could not save: \(message)"
    case .publicationUncertain:
      status.stringValue = ToolPublicationError.uncertain.localizedDescription
      recoveryButton.isHidden = recoveryURL == nil
    case .cancelled: status.stringValue = "Save cancelled. Your draft was kept."
    }
    if !result.succeeded { view.window?.makeFirstResponder(focus ?? sourceEditor.textView) }
    refreshButtons()
  }
  @objc public func discardDraft() {
    guard !isBusy else { return }
    if let original = draft?.original, let tool = tools.first(where: { $0.id == original.id }) {
      present(tool: tool)
    } else {
      rebuild()
    }
  }
  @objc public func toggleEnabled() {
    guard !isBusy else { return }
    if draft != nil {
      updateDraft { $0.isEnabled = enabledButton.state == .on }
      return
    }
    guard tools.indices.contains(toolsTable.selectedRow) else { return }
    let tool = tools[toolsTable.selectedRow], enabled = enabledButton.state == .on
    catalogMutation = true
    setSavingControls(true)
    Task { [weak self] in
      guard let self else { return }
      defer {
        catalogMutation = false
        setSavingControls(false)
        rebuild(select: tool.id)
      }
      do {
        if tool.origin == .bundledTemplate {
          snapshot = try await store.setTemplateEnabled(id: tool.id, enabled: enabled)
        } else if var definition = snapshot.customTools.first(where: { $0.id == tool.id }) {
          let revision = definition.revision
          definition.isEnabled = enabled
          snapshot = try await store.save(definition, expectedRevision: revision)
        }
        rebuild(select: tool.id)
      } catch {
        enabledButton.state = tool.isEnabled ? .on : .off
        status.stringValue = "Could not change enablement: \(error.localizedDescription)"
      }
    }
  }
  @objc public func deleteTool() {
    guard !isBusy else { return }
    guard let definition = draft?.original, let window = view.window else { return }
    let alert = NSAlert()
    alert.messageText = "Delete \(definition.displayName)?"
    alert.informativeText = "This removes its saved tool definition."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    if definition.basedOnTemplateID == definition.id {
      alert.messageText = "Restore bundled \(definition.displayName)?"
      alert.informativeText =
        "The bundled implementation and configuration will become active again. Saved override generations will be removed."
      alert.buttons.first?.title = "Restore"
    }
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self, !self.isBusy else { return }
      self.catalogMutation = true
      self.setSavingControls(true)
      Task {
        defer {
          self.catalogMutation = false
          self.setSavingControls(false)
        }
        do {
          self.snapshot = try await self.store.delete(
            id: definition.id, expectedRevision: definition.revision)
          self.rebuild()
          self.status.stringValue = "Tool deleted."
        } catch { self.status.stringValue = "Could not delete: \(error.localizedDescription)" }
      }
    }
  }
  @objc private func revealDiagnostic() {
    let row =
      diagnosticsTable.clickedRow >= 0 ? diagnosticsTable.clickedRow : diagnosticsTable.selectedRow
    guard diagnostics.indices.contains(row), let range = diagnostics[row].range else { return }
    sourceEditor.reveal(range)
  }
  public override func resolvePendingChanges(
    in window: NSWindow, completion: @escaping (Bool) -> Void
  ) {
    if let saveTask {
      Task { completion(await saveTask.value.succeeded) }
      return
    }
    guard hasUnsavedChanges else {
      completion(true)
      return
    }
    let alert = NSAlert()
    alert.messageText = "Save changes to this tool?"
    alert.informativeText = "Unsaved tool definition will be discarded if you leave."
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Discard")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else {
        completion(false)
        return
      }
      if response == .alertSecondButtonReturn {
        self.discardDraft()
        completion(true)
      } else if response == .alertFirstButtonReturn {
        Task { completion(await self.awaitSave().succeeded) }
      } else {
        completion(false)
      }
    }
  }
}
