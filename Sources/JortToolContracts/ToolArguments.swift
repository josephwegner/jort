import Foundation
import CoreFoundation

/// Values cross the JavaScript boundary as JSON numbers and strings, without enum wrappers.
public enum ToolArgumentValue: Codable, Equatable, Sendable {
  case integer(Int), string(String)
  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if let number = try? value.decode(Int.self) {
      self = .integer(number)
    } else {
      self = .string(try value.decode(String.self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .integer(let number): try value.encode(number)
    case .string(let text): try value.encode(text)
    }
  }
}

public struct ToolArgumentDefinition: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case integer, string, `enum` }
  public var name: String
  public var type: Kind
  public var label: String
  public var description: String?
  public var defaultValue: ToolArgumentValue?
  public var minimum: Int?
  public var maximum: Int?
  public var required: Bool?
  public var choices: [String]?
  public init(
    name: String, type: Kind, label: String, description: String? = nil,
    defaultValue: ToolArgumentValue? = nil, minimum: Int? = nil, maximum: Int? = nil,
    required: Bool? = nil, choices: [String]? = nil
  ) {
    self.name = name
    self.type = type
    self.label = label
    self.description = description
    self.defaultValue = defaultValue
    self.minimum = minimum
    self.maximum = maximum
    self.required = required
    self.choices = choices
  }
  public func validate() throws {
    guard name.range(of: #"^[a-zA-Z][a-zA-Z0-9_]{0,63}$"#, options: .regularExpression) != nil,
      !["__proto__", "constructor", "prototype"].contains(name),
      !label.isEmpty, label.utf8.count <= 256, (description?.utf8.count ?? 0) <= 4096,
      minimum == nil || maximum == nil || minimum! <= maximum!,
      type == .integer || (minimum == nil && maximum == nil),
      type == .enum || choices == nil,
      type != .enum || (choices?.isEmpty == false && (choices?.count ?? 0) <= 64),
      Set(choices ?? []).count == (choices?.count ?? 0),
      choices?.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }) ?? true
    else { throw ToolPackageError.invalidManifest }
    if let defaultValue, !accepts(defaultValue) { throw ToolPackageError.invalidManifest }
  }
  public func accepts(_ value: ToolArgumentValue) -> Bool {
    switch (type, value) {
    case (.integer, .integer(let number)):
      return abs(Double(number)) <= 9_007_199_254_740_991
        && number >= (minimum ?? Int.min) && number <= (maximum ?? Int.max)
    case (.string, .string(let text)): return text.utf8.count <= 16_384 && !text.contains("\0")
    case (.enum, .string(let text)): return choices?.contains(text) == true
    default: return false
    }
  }
}

/// Positional command text is parsed only from owned input or a separate argument field.
public enum ToolArguments {
  public static func parse(_ text: String, definitions: [ToolArgumentDefinition]) throws
    -> [String: ToolArgumentValue]
  {
    guard text.utf8.count <= 65_536 else { throw invalid("Arguments exceed the input limit.") }
    var tokens: [String] = [], token = "", quoted = false, started = false, escaped = false
    for character in text {
      if escaped {
        switch character {
        case "n": token.append("\n")
        case "r": token.append("\r")
        case "t": token.append("\t")
        case "\"", "\\": token.append(character)
        default: throw invalid("Unknown argument escape.")
        }
        escaped = false
      } else if character == "\\" {
        escaped = true
        started = true
      } else if character == "\"" {
        quoted.toggle()
        started = true
      } else if character.isWhitespace && !quoted {
        if started {
          tokens.append(token)
          token = ""
          started = false
        }
      } else {
        token.append(character)
        started = true
      }
    }
    guard !quoted && !escaped else { throw invalid("Close the quoted argument and its escape.") }
    if started { tokens.append(token) }
    guard tokens.count <= definitions.count else { throw invalid("Too many arguments.") }
    var values: [String: ToolArgumentValue] = [:]
    for (index, definition) in definitions.enumerated() where index < tokens.count {
      if definition.type == .integer {
        let token = tokens[index]
        guard token.range(of: #"^[+-]?[0-9]+$"#, options: .regularExpression) != nil,
          let integer = Int(token)
        else { throw invalid("\(definition.label) must be an integer.") }
        values[definition.name] = .integer(integer)
      } else {
        values[definition.name] = .string(tokens[index])
      }
    }
    return try validate(values, definitions: definitions)
  }
  public static func validate(
    _ values: [String: ToolArgumentValue], definitions: [ToolArgumentDefinition]
  ) throws -> [String: ToolArgumentValue] {
    guard values.count <= 16, Set(values.keys).isSubset(of: Set(definitions.map(\.name))) else {
      throw invalid("Unknown argument.")
    }
    var resolved = values
    for definition in definitions {
      try definition.validate()
      if resolved[definition.name] == nil { resolved[definition.name] = definition.defaultValue }
      if let value = resolved[definition.name] {
        guard definition.accepts(value) else { throw invalid("Invalid \(definition.label).") }
      } else if definition.required == true {
        throw invalid("Enter \(definition.label).")
      }
    }
    return resolved
  }
  private static func invalid(_ message: String) -> ToolFailure {
    .init(.invalidInput, message: message)
  }
}

public struct ToolLocalTime: Codable, Equatable, Sendable {
  public let year, month, day, weekday, hour, minute, second: Int
  public let timeZone, locale: String
  public init(date: Date, timeZone: TimeZone = .current, locale: Locale = .current) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents(
      [.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
    year = parts.year!
    month = parts.month!
    day = parts.day!
    weekday = parts.weekday! - 1
    hour = parts.hour!
    minute = parts.minute!
    second = parts.second!
    self.timeZone = timeZone.identifier
    self.locale = locale.identifier
  }
  public var isValid: Bool {
    (1...9999).contains(year) && (1...12).contains(month) && (1...31).contains(day)
      && (0...6).contains(weekday) && (0...23).contains(hour) && (0...59).contains(minute)
      && (0...59).contains(second) && timeZone.utf8.count <= 128 && locale.utf8.count <= 128
      && TimeZone(identifier: timeZone) != nil && !locale.isEmpty
  }
}

public struct ToolTextAnalysis: Codable, Equatable, Sendable {
  public let characters, charactersWithoutWhitespace, words: Int
  public let alphabeticalOrder: [Int]
  public let alphabeticalRanks: [Int]
  public init(
    characters: Int, charactersWithoutWhitespace: Int, words: Int, alphabeticalOrder: [Int],
    alphabeticalRanks: [Int] = []
  ) {
    self.characters = characters
    self.charactersWithoutWhitespace = charactersWithoutWhitespace
    self.words = words
    self.alphabeticalOrder = alphabeticalOrder
    self.alphabeticalRanks = alphabeticalRanks
  }
  public static func capture(content: String, locale: Locale = .current) throws -> Self {
    guard content.utf8.count <= 1_048_576, !locale.identifier.isEmpty,
      Locale.availableIdentifiers.contains(
        Locale.canonicalIdentifier(from: locale.identifier).components(separatedBy: "@")[0])
    else {
      throw ToolFailure(.invalidInput, message: "Text analysis locale or content is unsupported.")
    }
    // CFStringTokenizer accepts the captured locale explicitly; .byWords does not.
    let string = content as NSString
    let tokenizer = CFStringTokenizerCreate(
      kCFAllocatorDefault, string,
      CFRange(location: 0, length: string.length), kCFStringTokenizerUnitWordBoundary,
      (locale as NSLocale))!
    var words = 0
    while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
      let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
      let token = string.substring(with: NSRange(location: range.location, length: range.length))
      if token.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
        words += 1
      }
    }
    let lines = logicalLines(content)
    guard lines.count <= 100_000 else {
      throw ToolFailure(.invalidInput, message: "Too many lines for text analysis.")
    }
    let order = lines.indices.sorted { left, right in
      let comparison = lines[left].compare(
        lines[right], options: [.caseInsensitive], locale: locale)
      return comparison == .orderedSame ? left < right : comparison == .orderedAscending
    }
    var ranks = Array(repeating: 0, count: lines.count), rank = 0
    for position in order.indices {
      if position > 0
        && lines[order[position - 1]].compare(
          lines[order[position]],
          options: [.caseInsensitive], locale: locale) != .orderedSame
      {
        rank += 1
      }
      ranks[order[position]] = rank
    }
    return .init(
      characters: content.count,
      charactersWithoutWhitespace: content.filter { !$0.isWhitespace }.count,
      words: words, alphabeticalOrder: order, alphabeticalRanks: ranks)
  }
  public static func logicalLines(_ content: String) -> [String] {
    guard !content.isEmpty else { return [] }
    let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var lines = normalized.components(separatedBy: "\n")
    if normalized.hasSuffix("\n") { lines.removeLast() }
    return lines
  }
}

public struct ToolHostAction: Codable, Equatable, Sendable {
  public static let allowedKinds = ["clipboard.rich", "file.export", "notification.schedule"]
  public let kind, content: String
  public let minutes: Int?
  public let filename: String?
  public init(kind: String, content: String, minutes: Int? = nil, filename: String? = nil) {
    self.kind = kind
    self.content = content
    self.minutes = minutes
    self.filename = filename
  }
  private enum CodingKeys: String, CodingKey { case kind, content, minutes, filename }
  public init(from decoder: Decoder) throws {
    try requireFields(decoder, allowed: ["kind", "content", "minutes", "filename"])
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      kind: try fields.decode(String.self, forKey: .kind),
      content: try fields.decode(String.self, forKey: .content),
      minutes: try fields.decodeIfPresent(Int.self, forKey: .minutes),
      filename: try fields.decodeIfPresent(String.self, forKey: .filename))
    guard isValid else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Invalid action."))
    }
  }
  public var isValid: Bool {
    Self.allowedKinds.contains(kind) && content.utf8.count <= 1_048_576 && !content.contains("\0")
      && (kind == "notification.schedule"
        ? minutes.map { (1...525600).contains($0) } == true : minutes == nil)
      && (filename == nil
        || (kind == "file.export" && filename!.utf8.count <= 256
          && !filename!.isEmpty && !filename!.contains("/") && !filename!.contains("\\")
          && !filename!.contains("\0") && filename != "." && filename != ".."))
  }
}

public struct ToolOutputLandmark: Codable, Equatable, Sendable {
  public let line: Int
  public let emoji: String
  public init(line: Int, emoji: String) {
    self.line = line
    self.emoji = emoji
  }
  private enum CodingKeys: String, CodingKey { case line, emoji }
  public init(from decoder: Decoder) throws {
    try requireFields(decoder, allowed: ["line", "emoji"])
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      line: try fields.decode(Int.self, forKey: .line),
      emoji: try fields.decode(String.self, forKey: .emoji))
    guard isValid else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Invalid landmark."))
    }
  }
  public var isValid: Bool {
    (0..<100_000).contains(line) && emoji.count == 1 && emoji.utf8.count <= 64
      && emoji.unicodeScalars.contains { $0.properties.isEmoji }
  }
}

private struct PayloadField: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
private func requireFields(_ decoder: Decoder, allowed: Set<String>) throws {
  let fields = try decoder.container(keyedBy: PayloadField.self)
  guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
    throw DecodingError.dataCorrupted(
      .init(codingPath: decoder.codingPath, debugDescription: "Unknown payload field."))
  }
}

@MainActor public protocol ToolHostActionExecuting: AnyObject {
  func execute(action: ToolHostAction, identity: InvocationGeneration, input: ToolExecutionInput)
    async
    -> ToolExecutionResult
}
