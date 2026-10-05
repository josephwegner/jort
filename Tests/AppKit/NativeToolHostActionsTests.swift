import AppKit
import JortToolContracts
import XCTest
@testable import JortAppKit

@MainActor private final class ReminderNotificationStub: NativeReminderNotifications {
  var permission = true
  var permissionRequests = 0
  var requests: [(identifier: String, preview: String, deadline: Date)] = []
  var pending = Set<String>()
  var failAdd = false
  var afterAdd: (() throws -> Void)?
  func requestPermission() async throws -> Bool {
    permissionRequests += 1
    return permission
  }
  func add(identifier: String, preview: String, deadline: Date) async throws {
    requests.append((identifier, preview, deadline))
    if failAdd { throw CocoaError(.fileWriteUnknown) }
    pending.insert(identifier)
    try afterAdd?()
  }
  func pendingIdentifiers() async -> Set<String> { pending }
  func remove(identifier: String) { pending.remove(identifier) }
}

@MainActor final class NativeToolHostActionsTests: XCTestCase {
  private var directory: URL!
  private let date = Date(timeIntervalSince1970: 1_800_000_000)
  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDown() async throws {
    try FileManager.default.removeItem(at: directory)
  }
  private func identity() -> InvocationGeneration {
    .init(invocationID: UUID(), generation: UUID())
  }
  private func reminders(
    _ stub: ReminderNotificationStub,
    activation: @escaping @MainActor (NativeReminderReceipt) -> Void = { _ in }
  ) throws -> NativeToolReminders {
    try NativeToolReminders(
      receiptURL: directory.appendingPathComponent("receipts.json"),
      notifications: stub, now: { self.date }, onActivation: activation)
  }

  func testRichCopyPublishesReadablePlainTextHTMLAndNativeRTF() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let host = NativeToolHostActions(
      reminders: try reminders(ReminderNotificationStub()), pasteboard: pasteboard)
    let source =
      "# Heading\n**Bold** and *emphasis*\n- item\n> quote\n`code` [link](https://example.com)"
    let result = await host.execute(
      action: .init(kind: "clipboard.rich", content: source),
      identity: identity(), input: .init(content: source))
    XCTAssertNotNil(result.report)
    let plain = try XCTUnwrap(pasteboard.string(forType: .string))
    XCTAssertTrue(plain.contains("Bold and emphasis"))
    XCTAssertTrue(plain.contains("• item"))
    let html = try XCTUnwrap(pasteboard.string(forType: .html))
    XCTAssertTrue(html.contains("<strong>Bold</strong>"))
    XCTAssertTrue(html.contains("<blockquote>quote</blockquote>"))
    let rtf = try XCTUnwrap(pasteboard.data(forType: .rtf))
    let attributed = try NSAttributedString(
      data: rtf,
      options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    XCTAssertEqual(attributed.string, plain)
    let boldRange = (plain as NSString).range(of: "Bold")
    let font = try XCTUnwrap(
      attributed.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
  }

  func testRawHTMLImagesAndUnsafeLinksAreInert() throws {
    let rendered = try NativeRichClipboard.representations(
      "<script>alert(1)</script> ![photo](https://example.com/image.png) [bad](javascript:alert)")
    let html = try XCTUnwrap(String(data: rendered.html, encoding: .utf8))
    XCTAssertFalse(html.contains("<script>"))
    XCTAssertFalse(html.contains("<img"))
    XCTAssertFalse(html.contains("href=\"javascript:"))
    XCTAssertTrue(rendered.plainText.contains("<script>alert(1)</script> photo bad"))
  }

  func testMarkdownFenceMarkerLengthTailAndIndentation() throws {
    let source =
      "   ````swift\n# literal\n```\n~~~\n```` trailing\n**literal**\n`````   \n# Heading ###"
    let rendered = try NativeRichClipboard.representations(source)
    let html = try XCTUnwrap(String(data: rendered.html, encoding: .utf8))
    XCTAssertTrue(
      html.contains("<pre><code># literal\n```\n~~~\n```` trailing\n**literal**\n</code></pre>"))
    XCTAssertTrue(html.contains("<h1>Heading</h1>"))
    XCTAssertFalse(html.contains("<strong>literal</strong>"))
    let indented = try NativeRichClipboard.representations(
      "    ```\n    **literal**\n    # literal\n# real")
    let indentedHTML = try XCTUnwrap(String(data: indented.html, encoding: .utf8))
    XCTAssertTrue(indentedHTML.contains("<pre><code>    **literal**</code></pre>"))
    XCTAssertFalse(indentedHTML.contains("<strong>"))
    XCTAssertTrue(indentedHTML.contains("<h1>real</h1>"))
  }

  func testATXAndSingleLineSetextHeadings() throws {
    let rendered = try NativeRichClipboard.representations(
      "   ## ATX ###\nTitle\n===\nSubtitle\n  ---\n####### literal\n    # indented\n# adjacent#")
    let html = try XCTUnwrap(String(data: rendered.html, encoding: .utf8))
    XCTAssertTrue(html.contains("<h2>ATX</h2>"))
    XCTAssertTrue(html.contains("<h1>Title</h1>"))
    XCTAssertTrue(html.contains("<h2>Subtitle</h2>"))
    XCTAssertTrue(html.contains("<p>####### literal</p>"))
    XCTAssertTrue(html.contains("<pre><code>    # indented</code></pre>"))
    XCTAssertTrue(html.contains("<h1>adjacent#</h1>"))
    XCTAssertFalse(rendered.plainText.contains("===") || rendered.plainText.contains("---"))
  }

  func testExportWritesExactUTF8ToPanelDestination() async throws {
    let destination = directory.appendingPathComponent("chosen.txt")
    let source = "# Héllo 👨‍👩‍👧‍👦\r\n**Keep Markdown**\n"
    var suggestion = ""
    let host = NativeToolHostActions(
      reminders: try reminders(ReminderNotificationStub()),
      chooseExportDestination: { name in
        suggestion = name
        return destination
      })
    let result = await host.execute(
      action: .init(kind: "file.export", content: source),
      identity: identity(), input: .init(content: source))
    XCTAssertNotNil(result.report)
    XCTAssertTrue(suggestion.hasSuffix(".md"))
    XCTAssertEqual(try Data(contentsOf: destination), Data(source.utf8))
  }

  func testExportCancellationAndFailureNeverReportSuccess() async throws {
    let reminders = try reminders(ReminderNotificationStub())
    let cancelled = NativeToolHostActions(
      reminders: reminders, chooseExportDestination: { _ in nil })
    let result = await cancelled.execute(
      action: .init(kind: "file.export", content: "text"),
      identity: identity(), input: .init(content: "text"))
    XCTAssertEqual(result.failure?.code, .cancelled)
    XCTAssertNil(result.report)
    let failed = NativeToolHostActions(
      reminders: reminders, chooseExportDestination: { _ in self.directory })
    let failure = await failed.execute(
      action: .init(kind: "file.export", content: "text"),
      identity: identity(), input: .init(content: "text"))
    XCTAssertNotNil(failure.error)
    XCTAssertNil(failure.report)
  }

  func testContentMismatchDoesNotOpenSavePanel() async throws {
    var opened = false
    let host = NativeToolHostActions(
      reminders: try reminders(ReminderNotificationStub()),
      chooseExportDestination: { _ in
        opened = true
        return nil
      })
    let result = await host.execute(
      action: .init(kind: "file.export", content: "changed"),
      identity: identity(), input: .init(content: "captured"))
    XCTAssertNotNil(result.error)
    XCTAssertFalse(opened)
  }

  func testFilenameCannotContainPathOrControlCharacters() {
    XCTAssertEqual(NativeToolHostActions.filename(content: ""), "note.md")
    XCTAssertEqual(NativeToolHostActions.filename(content: "# My note\nbody"), "My note.md")
    let name = NativeToolHostActions.filename(content: "", suggestion: "../../secret:\nfile")
    XCTAssertFalse(name.contains("/"))
    XCTAssertFalse(name.contains(":"))
    XCTAssertFalse(name.contains("\n"))
  }

  func testUnavailableReminderStoreStillAllowsClipboardAndExport() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let destination = directory.appendingPathComponent("note.md")
    let host = NativeToolHostActions(
      reminders: nil, pasteboard: pasteboard,
      chooseExportDestination: { _ in destination })
    let input = ToolExecutionInput(content: "**captured**", date: date)
    for kind in ["clipboard.rich", "file.export"] {
      let result = await host.execute(
        action: .init(kind: kind, content: input.content),
        identity: identity(), input: input)
      XCTAssertNotNil(result.report)
    }
    XCTAssertEqual(pasteboard.string(forType: .string), "captured")
    XCTAssertEqual(try Data(contentsOf: destination), Data(input.content.utf8))
    let unavailable = await host.execute(
      action: .init(kind: "notification.schedule", content: input.content, minutes: 1),
      identity: identity(), input: input)
    XCTAssertNil(unavailable.report)
    XCTAssertTrue(unavailable.error?.contains("Reminder storage is unavailable") == true)
  }

  func testRejectedDispatchPreparationBlocksEveryNativeAction() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Existing clipboard", forType: .string)
    let originalChangeCount = pasteboard.changeCount
    let stub = ReminderNotificationStub(), service = try reminders(stub)
    let destination = directory.appendingPathComponent("untouched.md")
    var panelOpened = false
    var preparedIdentities: [InvocationGeneration] = []
    let host = NativeToolHostActions(
      reminders: service, pasteboard: pasteboard,
      chooseExportDestination: { _ in
        panelOpened = true
        return destination
      },
      beforeDispatch: { identity in
        await Task.yield()
        preparedIdentities.append(identity)
        return false
      })
    let generation = identity(), input = ToolExecutionInput(content: "captured", date: date)
    for kind in ["clipboard.rich", "file.export", "notification.schedule"] {
      let result = await host.execute(
        action: .init(
          kind: kind, content: input.content,
          minutes: kind == "notification.schedule" ? 1 : nil),
        identity: generation, input: input)
      XCTAssertNil(result.report)
      XCTAssertTrue(result.error?.contains("No action was performed") == true)
    }
    XCTAssertEqual(preparedIdentities, [generation, generation, generation])
    XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
    XCTAssertEqual(pasteboard.string(forType: .string), "Existing clipboard")
    XCTAssertFalse(panelOpened)
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertEqual(stub.permissionRequests, 0)
    XCTAssertTrue(stub.requests.isEmpty)
    XCTAssertTrue(service.receipts.isEmpty)
  }

  func testCancellationDuringDispatchPreparationBlocksEveryNativeAction() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Existing clipboard", forType: .string)
    let originalChangeCount = pasteboard.changeCount
    let stub = ReminderNotificationStub(), service = try reminders(stub)
    var panelOpened = false
    let host = NativeToolHostActions(
      reminders: service, pasteboard: pasteboard,
      chooseExportDestination: { _ in
        panelOpened = true
        return nil
      },
      beforeDispatch: { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        await Task.yield()
        return true
      })
    let generation = identity(), input = ToolExecutionInput(content: "captured", date: date)
    for kind in ["clipboard.rich", "file.export", "notification.schedule"] {
      let task = Task { @MainActor in
        await host.execute(
          action: .init(
            kind: kind, content: input.content,
            minutes: kind == "notification.schedule" ? 1 : nil),
          identity: generation, input: input)
      }
      let result = await task.value
      XCTAssertEqual(result.failure?.code, .cancelled)
      XCTAssertNil(result.report)
    }
    XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
    XCTAssertFalse(panelOpened)
    XCTAssertEqual(stub.permissionRequests, 0)
    XCTAssertTrue(stub.requests.isEmpty)
    XCTAssertTrue(service.receipts.isEmpty)
  }

  func testReminderDeadlineFullTextReloadAndNoReplay() async throws {
    let stub = ReminderNotificationStub(), generation = identity()
    let service = try reminders(stub)
    let text = String(repeating: "👨‍👩‍👧‍👦", count: 200) + " captured ending"
    let first = try await service.schedule(
      content: text, minutes: 12, submittedAt: date, identity: generation)
    XCTAssertNotNil(first.report)
    XCTAssertEqual(stub.requests.first?.deadline, date.addingTimeInterval(720))
    XCTAssertEqual(
      stub.requests.first?.preview,
      UTF8Bounds.prefix(String(text.prefix(180)), maximumBytes: 512))
    XCTAssertEqual(service.receipts.first?.status, .accepted)
    var activated: NativeReminderReceipt?
    let restored = try reminders(stub, activation: { activated = $0 })
    _ = try await restored.schedule(
      content: text, minutes: 12, submittedAt: date, identity: generation)
    XCTAssertEqual(stub.requests.count, 1)
    try restored.activate(identifier: NativeToolReminders.identifier(for: generation))
    XCTAssertEqual(activated?.content, text)
    XCTAssertEqual(activated?.status, .delivered)
    try restored.dismiss(identifier: NativeToolReminders.identifier(for: generation))
    XCTAssertTrue(restored.receipts.isEmpty)
  }

  func testDeniedPermissionAndInvalidDelayHaveNoReceiptOrDispatch() async throws {
    let stub = ReminderNotificationStub()
    stub.permission = false
    let service = try reminders(stub)
    let invalid = try await service.schedule(
      content: "text", minutes: 0, submittedAt: date, identity: identity())
    XCTAssertNotNil(invalid.error)
    XCTAssertEqual(stub.permissionRequests, 0)
    let denied = try await service.schedule(
      content: "text", minutes: 1, submittedAt: date, identity: identity())
    XCTAssertEqual(denied.failure?.code, .authorization)
    XCTAssertTrue(stub.requests.isEmpty)
    XCTAssertTrue(service.receipts.isEmpty)
  }

  func testUnknownReceiptSurvivesReloadAndPreventsAutomaticRetry() async throws {
    let stub = ReminderNotificationStub(), generation = identity()
    stub.failAdd = true
    let service = try reminders(stub)
    let result = try await service.schedule(
      content: "text", minutes: 1, submittedAt: date, identity: generation)
    XCTAssertNil(result.report)
    XCTAssertTrue(result.error?.contains("could not be confirmed") == true)
    XCTAssertEqual(result.failure?.code, .internalError)
    XCTAssertEqual(service.receipts.first?.status, .unknown)
    let restored = try reminders(stub)
    _ = try await restored.schedule(
      content: "text", minutes: 1, submittedAt: date, identity: generation)
    XCTAssertEqual(stub.requests.count, 1)
  }

  func testOSAcceptanceThenReceiptWriteFailureRemainsUnknownWithoutRedispatch() async throws {
    let stub = ReminderNotificationStub(), generation = identity()
    let service = try reminders(stub)
    let receiptURL = directory.appendingPathComponent("receipts.json")
    // Replace only this test's receipt file after the simulated OS acceptance.
    stub.afterAdd = {
      try FileManager.default.removeItem(at: receiptURL)
      try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: false)
    }
    let result = try await service.schedule(
      content: "captured", minutes: 1, submittedAt: date, identity: generation)
    XCTAssertNil(result.report)
    XCTAssertEqual(result.failure?.code, .internalError)
    XCTAssertTrue(result.error?.contains("OS accepted") == true)
    XCTAssertEqual(service.receipts.first?.status, .unknown)
    XCTAssertTrue(stub.pending.contains(NativeToolReminders.identifier(for: generation)))
    _ = try await service.schedule(
      content: "captured", minutes: 1,
      submittedAt: date, identity: generation)
    XCTAssertEqual(stub.requests.count, 1)
  }

  func testReceiptWriteFailureBeforeOSDispatchIsKnownFailure() async throws {
    let stub = ReminderNotificationStub(), service = try reminders(stub)
    let receiptURL = directory.appendingPathComponent("receipts.json")
    try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: false)
    let host = NativeToolHostActions(reminders: service)
    let result = await host.execute(
      action: .init(kind: "notification.schedule", content: "captured", minutes: 1),
      identity: identity(), input: .init(content: "captured", date: date))
    XCTAssertNil(result.report)
    XCTAssertEqual(result.failure?.code, .implementation)
    XCTAssertTrue(stub.requests.isEmpty)
    XCTAssertTrue(service.receipts.isEmpty)
  }

  func testCancellationAndDeliveredFeedback() async throws {
    let stub = ReminderNotificationStub(), service = try reminders(stub)
    let generation = identity(), identifier = NativeToolReminders.identifier(for: generation)
    _ = try await service.schedule(
      content: "text", minutes: 1, submittedAt: date, identity: generation)
    let cancelled = await service.cancel(identifier: identifier)
    XCTAssertTrue(cancelled.report?.contains("Cancelled") == true)
    XCTAssertTrue(stub.pending.isEmpty)
    XCTAssertEqual(service.receipts.first?.status, .cancelled)
    let delivered = await service.cancel(identifier: identifier)
    XCTAssertTrue(delivered.report?.contains("may already have been delivered") == true)
  }

  func testRetentionPrunesExpiredReceiptsOnReload() async throws {
    let stub = ReminderNotificationStub(), service = try reminders(stub)
    _ = try await service.schedule(
      content: "old", minutes: 1, submittedAt: date, identity: identity())
    let restored = try NativeToolReminders(
      receiptURL: directory.appendingPathComponent("receipts.json"),
      notifications: stub, now: { self.date.addingTimeInterval(31 * 24 * 60 * 60) },
      onActivation: { _ in })
    XCTAssertTrue(restored.receipts.isEmpty)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent("receipts.json").path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }
}
