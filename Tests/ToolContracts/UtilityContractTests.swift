import Foundation
import JortToolContracts
import XCTest

final class UtilityContractTests: XCTestCase {
  private let separator = ToolArgumentDefinition(
    name: "separator", type: .string, label: "Separator", required: true)
  private let width = ToolArgumentDefinition(
    name: "width", type: .integer, label: "Width", defaultValue: .integer(4), minimum: 1,
    maximum: 16)

  func testQuotedEmptyStringsWhitespaceAndEscapesRemainDistinctFromMissing() throws {
    XCTAssertThrowsError(try ToolArguments.parse("", definitions: [separator]))
    XCTAssertEqual(
      try ToolArguments.parse("\"\"", definitions: [separator]), ["separator": .string("")])
    XCTAssertEqual(
      try ToolArguments.parse("\" · \"", definitions: [separator]), ["separator": .string(" · ")])
    XCTAssertEqual(
      try ToolArguments.parse(#""\n\t\\\"""#, definitions: [separator]),
      ["separator": .string("\n\t\\\"")])
    XCTAssertThrowsError(try ToolArguments.parse(#""unfinished"#, definitions: [separator]))
    XCTAssertThrowsError(try ToolArguments.parse(#""\z""#, definitions: [separator]))
    XCTAssertThrowsError(try ToolArguments.parse("one two", definitions: [separator]))
  }

  func testDefaultsIntegerBoundsEnumChoicesAndUnknownKeys() throws {
    XCTAssertEqual(try ToolArguments.parse("", definitions: [width]), ["width": .integer(4)])
    XCTAssertEqual(try ToolArguments.parse("+16", definitions: [width]), ["width": .integer(16)])
    for value in ["0", "17", "1.5", "NaN", "999999999999999999999999"] {
      XCTAssertThrowsError(try ToolArguments.parse(value, definitions: [width]), value)
    }
    let choice = ToolArgumentDefinition(
      name: "length", type: .enum, label: "Length",
      defaultValue: .string("short"), choices: ["short", "long"])
    XCTAssertEqual(try ToolArguments.parse("", definitions: [choice]), ["length": .string("short")])
    XCTAssertThrowsError(try ToolArguments.parse("other", definitions: [choice]))
    XCTAssertThrowsError(try ToolArguments.validate(["extra": .integer(1)], definitions: [width]))
  }

  func testLegacyManifestsCannotSmuggleNewContracts() throws {
    var manifest = ToolManifest(id: "dev.test.contract", name: "Test", command: "/test")
    try manifest.validate()
    manifest.arguments = [width]
    XCTAssertThrowsError(try manifest.validate())
    manifest.schemaVersion = 3
    manifest.entryContract = 2
    manifest.executor = .javascript
    try manifest.validate()
    manifest.hostActions = ["github.gist"]
    XCTAssertThrowsError(try manifest.validate())
    manifest.hostActions = ["file.export"]
    try manifest.validate()
    manifest.executor = .model
    XCTAssertThrowsError(try manifest.validate())
  }

  func testResultUnionRejectsMixedUnknownAndMalformedPayloads() throws {
    let decoder = JSONDecoder()
    for text in [
      #"{}"#, #"{"output":"text","report":"count"}"#,
      #"{"report":"count","extra":true}"#,
      #"{"action":{"kind":"file.export","content":"note","minutes":1}}"#,
      #"{"action":{"kind":"clipboard.rich","content":"note","extra":true}}"#,
      #"{"output":"heading","landmark":{"line":0,"emoji":"📅","extra":true}}"#,
      #"{"report":"count","landmark":{"line":0,"emoji":"📅"}}"#,
      #"{"output":"text","landmark":{"line":-1,"emoji":"📅"}}"#,
    ] {
      XCTAssertThrowsError(
        try decoder.decode(ToolExecutionResult.self, from: Data(text.utf8)), text)
    }
    for result in [
      ToolExecutionResult(output: ""), .init(report: "Characters: 3"),
      .init(action: .init(kind: "clipboard.rich", content: "note")), .init(error: "Invalid input"),
    ] {
      let encoded = try JSONEncoder().encode(result)
      XCTAssertEqual(try decoder.decode(ToolExecutionResult.self, from: encoded), result)
    }
  }

  func testUnicodeAnalysisUsesCapturedLocaleAndStableCollationTies() throws {
    let locale = Locale(identifier: "en_US")
    let text = "can't won't café e\u{301} 👨‍👩‍👧‍👦"
    let analysis = try ToolTextAnalysis.capture(content: text, locale: locale)
    XCTAssertEqual(analysis.characters, text.count)
    XCTAssertEqual(analysis.charactersWithoutWhitespace, 16)
    XCTAssertEqual(analysis.words, 4)
    let sorted = try ToolTextAnalysis.capture(content: "apple\nApple\nbanana\n", locale: locale)
    XCTAssertEqual(sorted.alphabeticalOrder, [0, 1, 2])
    XCTAssertEqual(sorted.alphabeticalRanks, [0, 0, 1])
    for language in ["fr_FR", "ja_JP", "ar_SA"] {
      XCTAssertGreaterThan(
        try ToolTextAnalysis.capture(
          content: "Bonjour 日本語 العربية", locale: Locale(identifier: language)
        ).words, 0)
    }
    XCTAssertThrowsError(
      try ToolTextAnalysis.capture(content: "text", locale: Locale(identifier: "invalid_Jort")))
  }

  func testCapturedTimeAndArgumentsSurviveValueCopies() throws {
    let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-12T15:28:00Z"))
    let local = ToolLocalTime(
      date: date, timeZone: try XCTUnwrap(TimeZone(identifier: "America/Chicago")),
      locale: Locale(identifier: "en_US"))
    XCTAssertEqual(local.day, 12)
    XCTAssertEqual(local.month, 9)
    XCTAssertEqual(local.weekday, 6)
    XCTAssertEqual(local.hour, 10)
    let original = ToolExecutionInput(
      content: "exact source", date: date,
      localTime: local, entropy: [1, 2, 3])
    let copied = original.withArguments(["width": .integer(4)])
    XCTAssertEqual(copied.content, original.content)
    XCTAssertEqual(copied.clock, original.clock)
    XCTAssertEqual(copied.uuid, original.uuid)
    XCTAssertEqual(copied.localTime, local)
    XCTAssertEqual(copied.entropy, [1, 2, 3])
    XCTAssertTrue(original.arguments.isEmpty)
  }
}
