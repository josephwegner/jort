import JortToolContracts
import XCTest

final class InlineArgumentTests: XCTestCase {
  func testFreeQuestionKeepsQuotesUnicodeAndWhitespaceInsideIt() throws {
    let input = try ToolArguments.parseModelInputs(
      "  What does \"Kubernetes\" mean?  ", definitions: [])
    XCTAssertEqual(input.instruction, "What does \"Kubernetes\" mean?")
    XCTAssertTrue(input.arguments.isEmpty)
  }

  func testOptionalParameterCanPrecedeAQuestionOrUseItsDefault() throws {
    let definition = ToolArgumentDefinition(
      name: "length", type: .enum, label: "Length",
      defaultValue: .string("default"), choices: ["default", "short"])
    let explicit = try ToolArguments.parseModelInputs(
      "short Focus on decisions", definitions: [definition])
    XCTAssertEqual(explicit.arguments, ["length": .string("short")])
    XCTAssertEqual(explicit.instruction, "Focus on decisions")
    let implicit = try ToolArguments.parseModelInputs(
      "Focus on decisions", definitions: [definition])
    XCTAssertEqual(implicit.arguments, ["length": .string("default")])
    XCTAssertEqual(implicit.instruction, "Focus on decisions")
  }

  func testRequiredQuotedParametersPreserveTheirBoundaries() throws {
    let definitions = [
      ToolArgumentDefinition(name: "label", type: .string, label: "Label", required: true),
      ToolArgumentDefinition(name: "count", type: .integer, label: "Count", required: true),
    ]
    let input = try ToolArguments.parseModelInputs(
      "\"two words\" 3 Explain this term", definitions: definitions)
    XCTAssertEqual(input.arguments, ["label": .string("two words"), "count": .integer(3)])
    XCTAssertEqual(input.instruction, "Explain this term")
    XCTAssertThrowsError(
      try ToolArguments.parseModelInputs("label nope Explain", definitions: definitions))
  }
}
