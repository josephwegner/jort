import AppKit
import JortToolContracts
import UserNotifications

public struct NativeReminderReceipt: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case unknown, accepted, delivered, cancelled }
  public let identifier: String
  public let content: String
  public let deadline: Date
  public var status: Status
}

/// Injectable OS boundary: tests never request permission or schedule real notifications.
@MainActor public protocol NativeReminderNotifications: AnyObject {
  func requestPermission() async throws -> Bool
  func add(identifier: String, preview: String, deadline: Date) async throws
  func pendingIdentifiers() async -> Set<String>
  func remove(identifier: String)
}

@MainActor public final class NativeToolReminders: NSObject, UNUserNotificationCenterDelegate {
  public private(set) var receipts: [NativeReminderReceipt]
  private let receiptURL: URL
  private let notifications: any NativeReminderNotifications
  private let now: @MainActor () -> Date
  private let onActivation: @MainActor (NativeReminderReceipt) -> Void
  private var scheduling = Set<String>()
  private static let maximumBytes = 8_388_608
  private static let retention: TimeInterval = 30 * 24 * 60 * 60

  public init(
    receiptURL: URL,
    notifications: (any NativeReminderNotifications)? = nil,
    now: @escaping @MainActor () -> Date = { Date() },
    onActivation: @escaping @MainActor (NativeReminderReceipt) -> Void
  ) throws {
    self.receiptURL = receiptURL
    self.notifications = notifications ?? SystemReminderNotifications()
    self.now = now
    self.onActivation = onActivation
    if FileManager.default.fileExists(atPath: receiptURL.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
      guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumBytes else {
        throw ToolFailure(.outputLimit, message: "Reminder receipts exceed the storage limit.")
      }
      receipts = try JSONDecoder().decode(
        [NativeReminderReceipt].self, from: Data(contentsOf: receiptURL))
      guard receipts.count <= 64, receipts.allSatisfy({ $0.content.utf8.count <= 1_048_576 }),
        Set(receipts.map(\.identifier)).count == receipts.count
      else {
        throw ToolFailure(.invalidInput, message: "Invalid reminder receipts.")
      }
    } else {
      receipts = []
    }
    super.init()
    try pruneExpired()
    if notifications == nil { UNUserNotificationCenter.current().delegate = self }
  }

  public static func identifier(for identity: InvocationGeneration) -> String {
    "jort.tool-reminder.\(identity.invocationID.uuidString.lowercased()).\(identity.generation.uuidString.lowercased())"
  }

  public func schedule(
    content: String, minutes: Int, submittedAt: Date,
    identity: InvocationGeneration
  ) async throws -> ToolExecutionResult {
    guard (1...525_600).contains(minutes), content.utf8.count <= 1_048_576 else {
      return .init(error: "Invalid reminder content or delay.")
    }
    try pruneExpired()
    let identifier = Self.identifier(for: identity)
    guard scheduling.insert(identifier).inserted else {
      return .init(error: "This reminder generation is already being scheduled.")
    }
    defer { scheduling.remove(identifier) }
    if let existing = receipts.first(where: { $0.identifier == identifier }) {
      if existing.status == .accepted { return acknowledgement(existing) }
      return .init(
        error:
          "This reminder generation has already been dispatched; its outcome is \(existing.status.rawValue). Use a new submission to retry."
      )
    }
    guard !Task.isCancelled else { throw CancellationError() }
    guard try await notifications.requestPermission() else {
      return .init(
        failure: .init(
          .authorization,
          message: "Allow Jort notifications in System Settings to schedule reminders."))
    }
    guard !Task.isCancelled else { throw CancellationError() }
    let receipt = NativeReminderReceipt(
      identifier: identifier, content: content,
      deadline: submittedAt.addingTimeInterval(TimeInterval(minutes) * 60), status: .unknown)
    guard receipts.count < 64 else {
      return .init(error: "Reminder storage is full. Cancel or dismiss an existing reminder first.")
    }
    // Persist intent first. A crash during add leaves unknown feedback, never a replay.
    try store(receipts + [receipt])
    do {
      try await notifications.add(
        identifier: identifier,
        preview: UTF8Bounds.prefix(String(content.prefix(180)), maximumBytes: 512),
        deadline: receipt.deadline)
    } catch {
      // An interrupted OS request may have taken effect. Retain the unknown receipt.
      return .init(
        failure: .init(
          .internalError,
          message:
            "Reminder acceptance could not be confirmed. It may have been scheduled; check notifications before retrying."
        ))
    }
    var accepted = receipt
    accepted.status = .accepted
    do { try store(receipts.map { $0.identifier == identifier ? accepted : $0 }) } catch {
      return .init(
        failure: .init(
          .internalError,
          message:
            "The OS accepted the reminder, but its receipt could not be saved. Do not retry automatically."
        ))
    }
    return acknowledgement(accepted)
  }

  public func cancel(identifier: String) async -> ToolExecutionResult {
    guard let receipt = receipts.first(where: { $0.identifier == identifier }) else {
      return .init(error: "The reminder receipt has expired or was dismissed.")
    }
    let pending = await notifications.pendingIdentifiers()
    guard pending.contains(identifier) else {
      return .init(
        report: "This reminder is no longer pending; it may already have been delivered.")
    }
    notifications.remove(identifier: identifier)
    var cancelled = receipt
    cancelled.status = .cancelled
    do { try store(receipts.map { $0.identifier == identifier ? cancelled : $0 }) } catch {
      return .init(error: "Cancellation was requested, but its receipt could not be saved.")
    }
    return .init(
      report:
        "Cancelled the pending reminder. An already delivered notification cannot be recalled.")
  }

  /// Full text comes from private storage rather than a truncated notification payload.
  public func activate(identifier: String) throws {
    try pruneExpired()
    guard var receipt = receipts.first(where: { $0.identifier == identifier }) else { return }
    receipt.status = .delivered
    onActivation(receipt)
    try store(receipts.map { $0.identifier == identifier ? receipt : $0 })
  }

  public func dismiss(identifier: String) throws {
    try store(receipts.filter { $0.identifier != identifier })
  }

  public func pruneExpired() throws {
    let retained = receipts.filter { $0.deadline.addingTimeInterval(Self.retention) > now() }
    if retained != receipts { try store(retained) }
  }

  private func store(_ updated: [NativeReminderReceipt]) throws {
    let data = try JSONEncoder().encode(updated)
    guard data.count <= Self.maximumBytes else {
      throw ToolFailure(
        .outputLimit, message: "Reminder storage is full. Dismiss an existing receipt first.")
    }
    try FileManager.default.createDirectory(
      at: receiptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: receiptURL, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    receipts = updated
  }

  private func acknowledgement(_ receipt: NativeReminderReceipt) -> ToolExecutionResult {
    .init(
      report:
        "Reminder accepted. Delivery follows notification settings and Focus. Cancellation ID: \(receipt.identifier)"
    )
  }

  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let identifier = response.notification.request.identifier
    let dismissed = response.actionIdentifier == UNNotificationDismissActionIdentifier
    Task { @MainActor [weak self] in
      if dismissed {
        try? self?.dismiss(identifier: identifier)
      } else {
        NSApplication.shared.activate(ignoringOtherApps: true)
        try? self?.activate(identifier: identifier)
      }
    }
    completionHandler()
  }

  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound, .list])
  }
}

@MainActor private final class SystemReminderNotifications: NativeReminderNotifications {
  private let center = UNUserNotificationCenter.current()
  func requestPermission() async throws -> Bool {
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral: return true
    case .notDetermined: return try await center.requestAuthorization(options: [.alert, .sound])
    default: return false
    }
  }
  func add(identifier: String, preview: String, deadline: Date) async throws {
    let content = UNMutableNotificationContent()
    content.title = "Jort reminder"
    content.body = preview
    content.sound = .default
    content.categoryIdentifier = "jort.tool-reminder"
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: content.categoryIdentifier,
        actions: [], intentIdentifiers: [], options: [.customDismissAction])
    ])
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: deadline)
    components.timeZone = calendar.timeZone
    let trigger: UNNotificationTrigger =
      deadline > Date()
      ? UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
      : UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
    try await center.add(
      UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
  }
  func pendingIdentifiers() async -> Set<String> {
    Set(await center.pendingNotificationRequests().map(\.identifier))
  }
  func remove(identifier: String) {
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }
}
