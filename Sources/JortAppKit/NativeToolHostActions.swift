import AppKit
import JortToolContracts
import UniformTypeIdentifiers

/// The coordinator validates the package and generation before calling this adapter.
@MainActor public final class NativeToolHostActions: ToolHostActionExecuting {
  public typealias ExportDestination = @MainActor (String) async -> URL?
  public typealias DispatchPreparation = @MainActor (InvocationGeneration) async -> Bool
  public let reminders: NativeToolReminders?
  private let pasteboard: NSPasteboard
  private let chooseExportDestination: ExportDestination
  private let beforeDispatch: DispatchPreparation

  public init(
    reminders: NativeToolReminders? = nil, pasteboard: NSPasteboard = .general,
    chooseExportDestination: @escaping ExportDestination = NativeToolHostActions.savePanel,
    beforeDispatch: @escaping DispatchPreparation = { _ in true }
  ) {
    self.reminders = reminders
    self.pasteboard = pasteboard
    self.chooseExportDestination = chooseExportDestination
    self.beforeDispatch = beforeDispatch
  }

  public func execute(
    action: ToolHostAction, identity: InvocationGeneration,
    input: ToolExecutionInput
  ) async -> ToolExecutionResult {
    guard !Task.isCancelled else {
      return .init(failure: .init(.cancelled, message: "Action cancelled."))
    }
    guard action.isValid, action.content == input.content else {
      return .init(error: "The action must use the exact captured content within the input limit.")
    }
    // App composition commits durable dispatch intent and rechecks the exact
    // invocation generation here. This adapter does not depend on persistence.
    let prepared = await beforeDispatch(identity)
    guard !Task.isCancelled else {
      return .init(failure: .init(.cancelled, message: "Action cancelled before dispatch."))
    }
    guard prepared else {
      return .init(error: "Action dispatch could not be durably prepared. No action was performed.")
    }
    do {
      switch action.kind {
      case "clipboard.rich":
        let representations = try NativeRichClipboard.representations(action.content)
        guard !Task.isCancelled else { throw CancellationError() }
        let item = NSPasteboardItem()
        item.setString(representations.plainText, forType: .string)
        item.setData(representations.rtf, forType: .rtf)
        item.setData(representations.html, forType: .html)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
          return .init(error: "The clipboard could not be updated.")
        }
        return .init(report: "Copied rich text. Clipboard changes cannot be undone here.")
      case "file.export":
        let suggestion = Self.filename(content: action.content, suggestion: action.filename)
        guard let url = await chooseExportDestination(suggestion) else {
          return .init(
            failure: .init(
              .cancelled, message: "Export cancelled. Your content is still available."))
        }
        guard !Task.isCancelled else { throw CancellationError() }
        try Data(action.content.utf8).write(to: url, options: .atomic)
        return .init(
          report: "Exported to \(url.lastPathComponent). File changes cannot be undone here.")
      case "notification.schedule":
        guard let reminders else {
          return .init(
            error:
              "Reminder storage is unavailable. Restore access to Jort’s private reminder receipts and restart Jort to schedule reminders."
          )
        }
        guard let minutes = action.minutes, (1...525_600).contains(minutes),
          let date = ISO8601DateFormatter().date(from: input.clock)
        else {
          return .init(error: "Enter a reminder delay between 1 and 525600 minutes.")
        }
        return try await reminders.schedule(
          content: action.content, minutes: minutes,
          submittedAt: date, identity: identity)
      default: return .init(error: "Unsupported native action.")
      }
    } catch is CancellationError {
      return .init(failure: .init(.cancelled, message: "Action cancelled before dispatch."))
    } catch {
      return .init(error: "Native action failed: \(error.localizedDescription)")
    }
  }

  public static func filename(content: String, suggestion: String? = nil) -> String {
    let firstLine =
      content.components(separatedBy: .newlines)
      .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "note"
    let source = suggestion ?? firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "# \t"))
    let safe = source.map { character -> Character in
      character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        || "/\\:".contains(character) ? "-" : character
    }
    var name = String(safe.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". \t"))
    if name.isEmpty { name = "note" }
    if !name.lowercased().hasSuffix(".md") && !name.lowercased().hasSuffix(".txt") { name += ".md" }
    return name
  }

  public static func savePanel(_ suggestion: String) async -> URL? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
    panel.nameFieldStringValue = suggestion
    panel.canCreateDirectories = true
    return await withCheckedContinuation { continuation in
      panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
    }
  }
}
