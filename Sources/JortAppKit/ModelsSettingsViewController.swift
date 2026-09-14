import AppKit
import JortSettings

@MainActor public final class ModelsSettingsViewController: SettingsPaneViewController {
  public let connection: OpenRouterConnection
  public let statusLabel = NSTextField(wrappingLabelWithString: "Not Connected")
  public let detailLabel = NSTextField(wrappingLabelWithString: "")
  public let connectButton = NSButton(title: "Connect with OpenRouter", target: nil, action: nil)
  public let checkButton = NSButton(title: "Check Connection", target: nil, action: nil)
  public let disconnectButton = NSButton(title: "Disconnect…", target: nil, action: nil)
  public let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  public let accountButton = NSButton(title: "Manage OpenRouter Account", target: nil, action: nil)
  public var openBrowser: @Sendable (URL) async -> Bool = { url in
    await MainActor.run { NSWorkspace.shared.open(url) }
  }
  private var job: Task<Void, Never>?
  private var connecting = false
  public init(connection: OpenRouterConnection) {
    self.connection = connection
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }
  deinit { job?.cancel() }
  public override var initialFirstResponder: NSResponder? { connectButton }
  public override func loadView() {
    let root = NSView(), title = NSTextField(labelWithString: "Models")
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    let provider = NSTextField(labelWithString: "OpenRouter")
    provider.font = .systemFont(ofSize: 17, weight: .semibold)
    let explanation = NSTextField(
      wrappingLabelWithString:
        "Connect in your browser to run model tools. Each run sends the tool’s instructions and submitted input to OpenRouter."
    )
    let buttons = NSStackView(views: [connectButton, checkButton, disconnectButton, cancelButton])
    buttons.orientation = .vertical
    buttons.alignment = .leading
    buttons.spacing = 8
    let stack = NSStackView(views: [
      title, provider, statusLabel, detailLabel, explanation, buttons, accountButton,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
    ])
    for button in [connectButton, checkButton, disconnectButton, cancelButton, accountButton] {
      button.target = self
    }
    connectButton.action = #selector(connect)
    checkButton.action = #selector(check)
    disconnectButton.action = #selector(disconnect)
    cancelButton.action = #selector(cancel)
    accountButton.action = #selector(account)
    statusLabel.setAccessibilityLabel("OpenRouter connection status")
    root.setAccessibilityLabel("Models settings")
    view = root
    cancelButton.isHidden = true
    Task { await refresh() }
  }
  public override func viewWillAppear() {
    super.viewWillAppear()
    Task { await refresh() }
  }
  public func refresh() async {
    let status = await connection.currentStatus(), available = await connection.available()
    let titles: [ModelConnectionState: String] = [
      .notConnected: "Not Connected", .connecting: "Connecting", .connected: "Connected",
      .unableToVerify: "Unable to Verify", .needsAttention: "Connection Needs Attention",
    ]
    statusLabel.stringValue =
      available || status.state == .connecting ? titles[status.state]! : "Not Connected"
    detailLabel.stringValue =
      status.lastVerified.map {
        "Last verified \($0.formatted(date: .abbreviated, time: .shortened))."
      } ?? "Connect to your OpenRouter account."
    connectButton.title = available ? "Replace Connection" : "Connect with OpenRouter"
    checkButton.isHidden = !available
    disconnectButton.isHidden = !available
    let active = job != nil
    if active && connecting { statusLabel.stringValue = "Connecting" }
    connectButton.isEnabled = !active
    checkButton.isEnabled = !active
    disconnectButton.isEnabled = !active
    cancelButton.isHidden = !active
  }
  private func perform(_ action: @escaping @Sendable () async throws -> Void) {
    guard job == nil else { return }
    job = Task { [weak self] in
      guard let self else { return }
      await refresh()
      do {
        try await action()
        job = nil
        connecting = false
        await refresh()
      } catch {
        job = nil
        connecting = false
        await refresh()
        detailLabel.stringValue =
          (error as? ModelFailure)?.message ?? "Connection was cancelled or could not be completed."
      }
    }
  }
  @objc public func connect() {
    guard job == nil else { return }
    connecting = true
    let connection = connection, browser = openBrowser
    perform { try await connection.connect(openBrowser: browser) }
    statusLabel.stringValue = "Connecting"
  }
  @objc public func check() {
    let connection = connection
    perform { try await connection.check() }
  }
  @objc public func cancel() { job?.cancel() }
  @objc public func account() {
    Task { _ = await openBrowser(URL(string: "https://openrouter.ai/settings/keys")!) }
  }
  @objc public func disconnect() {
    guard let window = view.window else { return }
    let alert = NSAlert()
    alert.messageText = "Disconnect OpenRouter?"
    alert.informativeText =
      "This removes the connection from this Mac. The key may remain active on OpenRouter. Revoke it using Manage OpenRouter Account."
    alert.addButton(withTitle: "Disconnect")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      let connection = self.connection
      self.perform { try await connection.disconnect() }
    }
  }
}
