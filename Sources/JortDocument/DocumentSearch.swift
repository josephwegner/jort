import Foundation
import CryptoKit

public struct SearchOptions: Equatable, Sendable {
  public var caseSensitive: Bool
  public var wholeWord: Bool
  public init(caseSensitive: Bool = false, wholeWord: Bool = false) {
    self.caseSensitive = caseSensitive
    self.wholeWord = wholeWord
  }
}

public struct SearchMatch: Equatable, Sendable {
  public let documentID: UUID
  public let generation: Int64
  public let lineID: UUID
  public let lineRange: NSRange
  public let matchedTextHash: Data
  public let ordinal: Int
  public let snippet: String

  /// A shifted logical line is safe; a missing identity or changed match is not.
  public func resolve(in snapshot: DocumentSnapshot) -> NSRange? {
    guard snapshot.documentID == documentID, snapshot.revision >= generation,
      let line = snapshot.lines.first(where: { $0.id == lineID }),
      lineRange.location >= 0, lineRange.location <= line.length
    else { return nil }
    let source = snapshot.text as NSString
    let start = line.location + lineRange.location
    guard start <= source.length, lineRange.length <= source.length - start else { return nil }
    let range = NSRange(location: start, length: lineRange.length)
    guard DocumentSearch.hash(source.substring(with: range)) == matchedTextHash else { return nil }
    return range
  }
}

public struct SearchPage: Sendable {
  public let matches: [SearchMatch]
  public let hasMore: Bool
}

/// Pure, local scanning. Call from a background task, never from an editor callback.
public enum DocumentSearch {
  public static func scan(
    _ snapshot: DocumentSnapshot, query: String, options: SearchOptions = .init(),
    limit: Int = 1_000
  ) throws -> SearchPage {
    try Task.checkCancellation()
    guard !query.isEmpty, limit > 0 else { return SearchPage(matches: [], hasMore: false) }
    // Escape user input: regular expressions are an implementation detail, not query syntax.
    // Word characters include combining marks and connectors, not only ASCII letters.
    let word = "[\\p{L}\\p{M}\\p{N}\\p{Pc}]"
    let literal = NSRegularExpression.escapedPattern(for: query)
    let pattern = options.wholeWord ? "(?<!\(word))\(literal)(?!\(word))" : literal
    let regex = try NSRegularExpression(
      pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
    let source = snapshot.text as NSString
    var matches: [SearchMatch] = [], lineIndex = 0, hasMore = false
    regex.enumerateMatches(
      in: snapshot.text, options: [.reportProgress],
      range: NSRange(location: 0, length: source.length)
    ) { match, _, stop in
      if Task.isCancelled {
        stop.pointee = true
        return
      }
      guard let range = match?.range else { return }
      if matches.count == limit {
        hasMore = true
        stop.pointee = true
        return
      }
      while lineIndex + 1 < snapshot.lines.count,
        snapshot.lines[lineIndex + 1].location <= range.location
      { lineIndex += 1 }
      guard snapshot.lines.indices.contains(lineIndex) else {
        stop.pointee = true
        return
      }
      let line = snapshot.lines[lineIndex]
      // Bound context in UTF-16 first, then expand only to composed-character boundaries.
      let start = max(line.location, range.location - 40)
      let length = min(160, line.location + line.length - start)
      let context = source.rangeOfComposedCharacterSequences(
        for: NSRange(location: start, length: length))
      var snippet = "", snippetLength = 0
      for character in source.substring(with: context) {
        if character.isNewline { break }
        let piece = String(character)
        guard snippetLength + piece.utf16.count <= 180 else {
          snippet += "…"
          break
        }
        snippet += piece
        snippetLength += piece.utf16.count
      }
      matches.append(
        SearchMatch(
          documentID: snapshot.documentID, generation: snapshot.revision, lineID: line.id,
          lineRange: NSRange(location: range.location - line.location, length: range.length),
          matchedTextHash: hash(source.substring(with: range)), ordinal: lineIndex + 1,
          snippet: snippet))
    }
    try Task.checkCancellation()
    return SearchPage(matches: matches, hasMore: hasMore)
  }

  static func hash(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }
}
