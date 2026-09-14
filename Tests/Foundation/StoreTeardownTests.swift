import Foundation
import XCTest

final class StoreTeardownTests: XCTestCase {
  private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
  }

  func testTeardownDrainsWorkThenClosesInReverseOrderBeforeRemovingRoot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let resources = TestStoreResources()
    let events = Events()
    resources.removeAfterClose(root)
    resources.retain {
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
      events.append("first")
    }
    resources.retain { events.append("second") }
    resources.prepare { events.append("drain") }
    await resources.cleanup()
    XCTAssertEqual(events.snapshot, ["drain", "second", "first"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    await resources.cleanup()
    XCTAssertEqual(events.snapshot.count, 3)
  }

  func testCleanupFailureIsSecondaryAndStillAttemptsEveryClose() async throws {
    enum Failure: Error { case primary, close }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let events = Events()
    let resources = TestStoreResources(report: { events.append($0) })
    resources.removeAfterClose(root)
    resources.retain { events.append("remaining close") }
    resources.retain { throw Failure.close }
    do {
      throw Failure.primary
    } catch {
      await resources.cleanup()
      XCTAssertEqual(error as? Failure, .primary)
    }
    XCTAssertTrue(events.snapshot.contains("remaining close"))
    XCTAssertTrue(events.snapshot.contains { $0.contains("Secondary store cleanup failure") })
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
  }
}
