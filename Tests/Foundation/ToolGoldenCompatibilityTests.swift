import JortToolContracts
import Foundation
import XCTest
import JortDocument
import JortSettings

final class ToolGoldenCompatibilityTests: XCTestCase {
  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
  }

  func testPreExtractionManifestPreservesDefaultsAndEncodedFields() throws {
    let data = try fixture("tool-manifest-pre-extraction")
    let value = try JSONDecoder().decode(ToolManifest.self, from: data)
    try value.validate()
    XCTAssertNil(value.executor)
    XCTAssertEqual(value.executorType, .javascript)
    XCTAssertEqual(value.inputMode, .contained)
    XCTAssertEqual(value.outputOperation.rawValue, "replace-invocation")
    XCTAssertEqual(value.maximumInputBytes, 262_144)
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary,
      try JSONSerialization.jsonObject(with: data) as? NSDictionary)
  }

  func testPreExtractionInvocationPhasesAnchorsHashesAndRestoration() throws {
    let data = try fixture("tool-invocations-pre-extraction")
    let values = try JSONDecoder().decode([ToolInvocation].self, from: data)
    XCTAssertEqual(values.map(\.phase), [.inputting, .submitted, .processing, .error, .pending])
    for value in values {
      XCTAssertNil(value.executor)
      XCTAssertEqual(value.sourceHash, ToolInvocation.hash("/calc 3+3"))
      XCTAssertEqual(value.token.start.offset, 0)
      XCTAssertEqual(value.scope.end.offset, 9)
      XCTAssertEqual(value.timestamp, Date(timeIntervalSinceReferenceDate: 12345))
      XCTAssertEqual(value.isLocked, value.phase != .inputting)
    }
    let pending = try XCTUnwrap(values.last)
    XCTAssertEqual(pending.outputHash, ToolInvocation.hash("6"))
    XCTAssertEqual(pending.restoration?.selection?.start.offset, 6)
    XCTAssertEqual(pending.restoration?.viewportOffset, 17.5)
    XCTAssertEqual(pending.restoration?.invocation(id: values[0].id), values[0])
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as? NSArray,
      try JSONSerialization.jsonObject(with: data) as? NSArray)
  }
}
