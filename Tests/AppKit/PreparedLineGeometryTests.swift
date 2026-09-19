import AppKit
import XCTest
@testable import JortAppKit

final class PreparedLineGeometryTests: XCTestCase {
  func testWrappedFragmentHasOneCanonicalBandAndAccessoryAfterLastVisualRow() {
    let id = UUID()
    let bands = PresentationGeometry.bands(
      in: .init(
        frame: NSRect(x: 0, y: 100, width: 300, height: 72),
        lines: [
          (0, NSRect(x: 0, y: 0, width: 300, height: 24)),
          (20, NSRect(x: 0, y: 24, width: 300, height: 24)),
          (40, NSRect(x: 0, y: 48, width: 100, height: 24)),
        ])
    ) {
      $0 == 0 ? .init(id: id, number: 8, accessoryHeight: 32) : nil
    }
    XCTAssertEqual(bands.count, 1)
    XCTAssertEqual(bands.first?.textY, 100)
    XCTAssertEqual(bands.first?.accessoryFrame?.minY, 172)
    XCTAssertEqual(bands.first?.accessoryFrame?.height, 32)
  }
  func testExtraEndRowUsesItsStableLineIdentity() {
    let id = UUID()
    let bands = PresentationGeometry.bands(
      in: .init(
        frame: NSRect(x: 0, y: 48, width: 300, height: 24),
        lines: [(10, NSRect(x: 0, y: 0, width: 0, height: 24))])
    ) {
      $0 == 10 ? .init(id: id, number: 3, accessoryHeight: 0) : nil
    }
    XCTAssertEqual(bands.first?.id, id)
    XCTAssertEqual(bands.first?.number, 3)
    XCTAssertNil(bands.first?.accessoryFrame)
  }
}
