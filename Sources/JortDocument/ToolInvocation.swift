import JortToolContracts
import Foundation
import CryptoKit

public struct ToolAnchor: Codable, Equatable, Sendable {
  public var lineID: UUID
  public var offset: Int
  public init(lineID: UUID, offset: Int) {
    self.lineID = lineID
    self.offset = offset
  }
  public func resolve(in lines: some RandomAccessCollection<LineMeta>) -> Int? {
    guard let line = lines.first(where: { $0.id == lineID }), offset >= 0, offset <= line.length
    else { return nil }
    return line.location + offset
  }
  public static func at(_ offset: Int, in lines: some RandomAccessCollection<LineMeta>) -> Self? {
    guard offset >= 0, let line = lines.last(where: { $0.location <= offset }),
      offset <= line.location + line.length
    else { return nil }
    return .init(lineID: line.id, offset: offset - line.location)
  }
}

public struct ToolAnchoredRange: Codable, Equatable, Sendable {
  public var start: ToolAnchor
  public var end: ToolAnchor
  public init(_ range: NSRange, lines: some RandomAccessCollection<LineMeta>) throws {
    guard range.location >= 0, range.length >= 0, range.length <= Int.max - range.location,
      let start = ToolAnchor.at(range.location, in: lines),
      let end = ToolAnchor.at(NSMaxRange(range), in: lines)
    else { throw DocumentError.invalidRange }
    self.start = start
    self.end = end
  }
  public func resolve(in lines: some RandomAccessCollection<LineMeta>) -> NSRange? {
    guard let a = start.resolve(in: lines), let b = end.resolve(in: lines), b >= a else {
      return nil
    }
    return NSRange(location: a, length: b - a)
  }
}

public struct ToolInvocationRestoration: Codable, Equatable, Sendable {
  public var packageID: String
  public var packageVersion: Int
  public var executor: String? = nil
  public var entryContract: Int
  public var inputMode: String
  public var outputOperation: String
  public var command: String
  public var token: ToolAnchoredRange
  public var scope: ToolAnchoredRange
  public var generation: UUID
  public var sourceHash: String
  public var timestamp: Date
  public var message: String?
  public var capturedArguments: [String: ToolArgumentValue]? = nil
  public var acceptanceSeparator: ToolAnchoredRange? = nil
  public var selection: ToolAnchoredRange?
  public var viewportLineID: UUID?
  public var viewportOffset: Double?

  public init(
    invocation: ToolInvocation, selection: ToolAnchoredRange? = nil,
    viewportLineID: UUID? = nil, viewportOffset: Double? = nil
  ) {
    packageID = invocation.packageID
    packageVersion = invocation.packageVersion
    executor = invocation.executor
    entryContract = invocation.entryContract
    inputMode = invocation.inputMode
    outputOperation = invocation.outputOperation
    command = invocation.command
    token = invocation.token
    scope = invocation.scope
    generation = invocation.generation
    sourceHash = invocation.sourceHash
    timestamp = invocation.timestamp
    message = invocation.message
    capturedArguments = invocation.capturedArguments
    acceptanceSeparator = invocation.acceptanceSeparator
    self.selection = selection
    self.viewportLineID = viewportLineID
    self.viewportOffset = viewportOffset
  }

  public func invocation(id: UUID) -> ToolInvocation {
    var value = ToolInvocation(
      packageID: packageID, packageVersion: packageVersion,
      entryContract: entryContract, inputMode: inputMode, outputOperation: outputOperation,
      command: command, token: token, scope: scope, sourceHash: sourceHash)
    value.executor = executor
    value.id = id
    value.generation = generation
    value.timestamp = timestamp
    value.message = message
    value.capturedArguments = capturedArguments
    value.acceptanceSeparator = acceptanceSeparator
    return value
  }
}

/// All stored content lives in the document. In particular, this type has no prompt field.
public struct ToolInvocation: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID = UUID()
  public var packageID: String
  public var packageVersion: Int
  public var executor: String? = nil
  public var entryContract: Int
  public var inputMode: String
  public var outputOperation: String
  public var command: String
  public var token: ToolAnchoredRange
  public var scope: ToolAnchoredRange
  public var output: ToolAnchoredRange?
  public var generation: UUID = UUID()
  public var phase: ToolInvocationPhase = .inputting
  public var sourceHash: String
  public var outputHash: String?
  public var timestamp: Date = Date()
  public var message: String?
  /// Only validated submission values are durable; unfinished field text belongs to the UI.
  public var capturedArguments: [String: ToolArgumentValue]? = nil
  public var acceptanceSeparator: ToolAnchoredRange? = nil
  public var actionStatus: ToolActionStatus? = nil
  public var actionKind: String? = nil
  public var outputLandmark: ToolOutputLandmark? = nil
  public var restoration: ToolInvocationRestoration?
  public var isLocked: Bool { phase != .inputting }
  public init(
    packageID: String, packageVersion: Int, entryContract: Int, inputMode: String,
    outputOperation: String, command: String, token: ToolAnchoredRange,
    scope: ToolAnchoredRange, sourceHash: String
  ) {
    self.packageID = packageID
    self.packageVersion = packageVersion
    self.entryContract = entryContract
    self.inputMode = inputMode
    self.outputOperation = outputOperation
    self.command = command
    self.token = token
    self.scope = scope
    self.sourceHash = sourceHash
  }
  public static func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public func validated(in snapshot: DocumentSnapshot) -> Bool {
    guard packageID.utf8.count <= 256, packageVersion > 0, (1...2).contains(entryContract),
      ["javascript", "model"].contains(executor ?? "javascript"),
      packageID.range(of: #"^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$"#, options: .regularExpression)
        != nil,
      command.utf8.count <= 65,
      command.range(of: #"^/[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil,
      timestamp.timeIntervalSinceReferenceDate.isFinite,
      (phase == .pending) == (output != nil),
      ["contained", "contextual", "ephemeralSingleLine", "ephemeralMultiline"].contains(inputMode),
      ["replace-invocation", "replace-context", "insert-at-invocation"].contains(outputOperation),
      outputOperation != "replace-context" || inputMode == "contextual",
      message?.utf8.count ?? 0 <= 1_048_576,
      Self.validArguments(capturedArguments),
      actionKind == nil
        || ["clipboard.rich", "file.export", "notification.schedule"].contains(actionKind!),
      (actionStatus == nil) == (actionKind == nil),
      actionStatus != .dispatched || [.submitted, .processing].contains(phase),
      actionStatus != .acknowledged && actionStatus != .unknown || phase == .completed,
      outputLandmark == nil || phase == .pending,
      let token = token.resolve(in: snapshot), let scope = scope.resolve(in: snapshot),
      NSMaxRange(scope) <= snapshot.utf16Count, token.location >= scope.location,
      NSMaxRange(token) <= NSMaxRange(scope),
      (try? snapshot.text(in: token)) == command
    else { return false }
    guard inputMode == "contextual" || scope.location == token.location,
      !inputMode.hasPrefix("ephemeral") || scope == token
    else { return false }
    if let restoration {
      guard restoration.packageID.utf8.count <= 256, restoration.packageVersion > 0,
        ["javascript", "model"].contains(restoration.executor ?? "javascript"),
        (1...2).contains(restoration.entryContract), restoration.command.utf8.count <= 65,
        restoration.timestamp.timeIntervalSinceReferenceDate.isFinite,
        restoration.message?.utf8.count ?? 0 <= 2048,
        Self.validArguments(restoration.capturedArguments),
        restoration.token.resolve(in: snapshot) != nil,
        restoration.scope.resolve(in: snapshot) != nil,
        restoration.selection?.resolve(in: snapshot) != nil || restoration.selection == nil,
        restoration.viewportOffset?.isFinite != false
      else { return false }
    }
    guard var source = try? snapshot.text(in: scope) else { return false }
    if let output {
      guard let range = output.resolve(in: snapshot), NSMaxRange(range) <= snapshot.utf16Count,
        range.location == (inputMode == "contained" ? NSMaxRange(scope) : NSMaxRange(token)),
        (try? snapshot.text(in: range)).map(Self.hash) == outputHash
      else { return false }
      if let landmark = outputLandmark {
        guard Landmark.isValidEmoji(landmark.emoji),
          let text = try? snapshot.text(in: range),
          Self.outputLineOffset(landmark.line, in: text) != nil
        else { return false }
      }
      let intersection = NSIntersectionRange(scope, range)
      if intersection.length > 0 {
        source = (source as NSString).replacingCharacters(
          in: NSRange(
            location: intersection.location - scope.location, length: intersection.length), with: ""
        )
      }
    }
    return Self.hash(source) == sourceHash
  }
  private static func validArguments(_ arguments: [String: ToolArgumentValue]?) -> Bool {
    guard let arguments else { return true }
    guard arguments.count <= 32, arguments.keys.allSatisfy({ $0.utf8.count <= 64 }),
      let data = try? JSONEncoder().encode(arguments)
    else { return false }
    return data.count <= 65_536
  }
  /// Return a UTF-16 offset without splitting a CRLF pair.
  static func outputLineOffset(_ line: Int, in text: String) -> Int? {
    guard line >= 0 else { return nil }
    if line == 0 { return 0 }
    let units = Array(text.utf16)
    var index = 0, current = 0
    while index < units.count {
      let unit = units[index]
      index += 1
      if unit == 13, index < units.count, units[index] == 10 { index += 1 }
      if [10, 13, 0x85, 0x2028, 0x2029].contains(unit) {
        current += 1
        if current == line { return index < units.count ? index : nil }
      }
    }
    return nil
  }
  public static func sanitized(_ values: [Self], in snapshot: DocumentSnapshot) -> [Self] {
    guard values.count <= 1000 else { return [] }
    let valid = values.filter { $0.validated(in: snapshot) }
    var seen = Set<UUID>(), rejected = Set<UUID>()
    let intervals = valid.compactMap { invocation -> (UUID, Int, Int)? in
      guard let scope = invocation.scope.resolve(in: snapshot) else { return nil }
      return (
        invocation.id, scope.location,
        max(
          NSMaxRange(scope),
          invocation.output?.resolve(in: snapshot).map(NSMaxRange) ?? NSMaxRange(scope))
      )
    }.sorted { $0.1 < $1.1 }
    var cluster: [UUID] = [], end = -1
    for (id, start, upper) in intervals {
      if !seen.insert(id).inserted { rejected.insert(id) }
      if start < end {
        rejected.formUnion(cluster)
        rejected.insert(id)
        cluster.append(id)
        end = max(end, upper)
      } else {
        cluster = [id]
        end = upper
      }
    }
    return valid.filter { !rejected.contains($0.id) }
  }
}

public enum ToolRangeEditing {
  public static func intersectsLock(_ edit: NSRange, snapshot: DocumentSnapshot) -> Bool {
    !intersectingLocks(edit, snapshot: snapshot).isEmpty
  }

  public static func intersectingLocks(_ edit: NSRange, snapshot: DocumentSnapshot)
    -> [ToolInvocation]
  {
    snapshot.invocations.filter { invocation in
      guard invocation.isLocked else { return false }
      guard let scope = invocation.scope.resolve(in: snapshot) else { return false }
      let end = max(
        NSMaxRange(scope),
        invocation.output?.resolve(in: snapshot).map(NSMaxRange) ?? NSMaxRange(scope))
      let range = NSRange(location: scope.location, length: end - scope.location)
      return edit.length == 0
        ? edit.location > range.location && edit.location < NSMaxRange(range)
        : NSIntersectionRange(edit, range).length > 0
    }
  }

  public static func remap(
    _ invocations: [ToolInvocation], from old: DocumentSnapshot, to new: DocumentSnapshot,
    edit: NSRange, replacementLength: Int
  ) -> [ToolInvocation] {
    let delta = replacementLength - edit.length
    func offset(_ value: Int, end: Bool) -> Int {
      if value < edit.location || value == edit.location && !end { return value }
      if value >= NSMaxRange(edit) { return value + delta }
      return edit.location + (end ? replacementLength : 0)
    }
    func range(_ value: ToolAnchoredRange, grow: Bool, growStart: Bool = false)
      -> ToolAnchoredRange?
    {
      guard let source = value.resolve(in: old) else { return nil }
      let a = offset(
        source.location, end: !growStart && edit.length == 0 && source.location == edit.location)
      let b = offset(NSMaxRange(source), end: grow)
      guard b >= a else { return nil }
      return try? ToolAnchoredRange(NSRange(location: a, length: b - a), snapshot: new)
    }
    return invocations.compactMap { original in
      guard let oldToken = original.token.resolve(in: old),
        NSIntersectionRange(oldToken, edit).length == 0
      else { return nil }
      var value = original
      guard let token = range(value.token, grow: false),
        let scope = range(
          value.scope, grow: !value.isLocked && !value.inputMode.hasPrefix("ephemeral"),
          growStart: !value.isLocked && value.inputMode == "contextual")
      else { return nil }
      value.token = token
      value.scope = scope
      if let separator = value.acceptanceSeparator {
        if let source = separator.resolve(in: old), NSIntersectionRange(source, edit).length == 0 {
          value.acceptanceSeparator = range(separator, grow: false)
        } else {
          value.acceptanceSeparator = nil
        }
      }
      if let output = value.output { value.output = range(output, grow: false) }
      if var restoration = value.restoration {
        guard let token = range(restoration.token, grow: false),
          let scope = range(restoration.scope, grow: false)
        else { return nil }
        restoration.token = token
        restoration.scope = scope
        if let separator = restoration.acceptanceSeparator {
          restoration.acceptanceSeparator = range(separator, grow: false)
        }
        if let selection = restoration.selection {
          restoration.selection = range(selection, grow: false)
        }
        value.restoration = restoration
      }
      if !value.isLocked, let source = scope.resolve(in: new),
        NSMaxRange(source) <= new.utf16Count
      {
        guard let text = try? new.text(in: source) else { return nil }
        value.sourceHash = ToolInvocation.hash(text)
      }
      return value.validated(in: new) ? value : nil
    }
  }
}

// Indexed anchor queries for ordinary transactions. Array overloads remain for
// explicit flat compatibility consumers during migration.
extension ToolAnchor {
  public func resolve(in snapshot: DocumentSnapshot) -> Int? {
    guard let line = snapshot.line(id: lineID), offset >= 0, offset <= line.length else {
      return nil
    }
    return line.location + offset
  }
  public static func at(_ offset: Int, in snapshot: DocumentSnapshot) -> Self? {
    guard let line = snapshot.line(containingUTF16Offset: offset), offset >= 0,
      offset <= line.location + line.length
    else { return nil }
    return .init(lineID: line.id, offset: offset - line.location)
  }
}
extension ToolAnchoredRange {
  public init(_ range: NSRange, snapshot: DocumentSnapshot) throws {
    guard range.location >= 0, range.length >= 0, range.length <= Int.max - range.location,
      let start = ToolAnchor.at(range.location, in: snapshot),
      let end = ToolAnchor.at(NSMaxRange(range), in: snapshot)
    else { throw DocumentError.invalidRange }
    self.start = start
    self.end = end
  }
  public func resolve(in snapshot: DocumentSnapshot) -> NSRange? {
    guard let a = start.resolve(in: snapshot), let b = end.resolve(in: snapshot), b >= a else {
      return nil
    }
    return NSRange(location: a, length: b - a)
  }
}
