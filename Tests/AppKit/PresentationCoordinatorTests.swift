import XCTest
@testable import JortAppKit

@MainActor final class PresentationCoordinatorTests: XCTestCase {
  func testBurstUnionsReasonsAndCommitsOnce() async {
    let coordinator = PresentationCoordinator()
    var received: PresentationDirtyReasons = []
    var commits = 0
    coordinator.prepare = { reasons in
      received = reasons
      return { commits += 1 }
    }
    for _ in 0..<100 { coordinator.invalidate(.viewport) }
    coordinator.invalidate(.document)
    XCTAssertEqual(commits, 0)
    await drain()
    XCTAssertEqual(received, [.viewport, .document])
    XCTAssertEqual(commits, 1)
    XCTAssertEqual(coordinator.state.passes, 1)
    XCTAssertEqual(coordinator.state.committedEpoch, coordinator.state.epoch)
  }
  func testStalePreparationNeverCommitsAndHasOneFollowup() async {
    let coordinator = PresentationCoordinator()
    var preparations = 0, commits = 0
    coordinator.prepare = { _ in
      preparations += 1
      if preparations == 1 {
        for _ in 0..<100 { coordinator.invalidate(.lifecycle) }
      }
      return { commits += 1 }
    }
    coordinator.invalidate(.document)
    await drain()
    XCTAssertEqual(preparations, 2)
    XCTAssertEqual(commits, 1)
    XCTAssertEqual(coordinator.state.committedEpoch, coordinator.state.epoch)
  }
  func testCommitInvalidationSchedulesWithoutRecursion() async {
    let coordinator = PresentationCoordinator()
    var depth = 0, maximumDepth = 0, commits = 0
    coordinator.prepare = { _ in
      return {
        depth += 1
        maximumDepth = max(depth, maximumDepth)
        commits += 1
        if commits == 1 { coordinator.invalidate(.layout) }
        depth -= 1
      }
    }
    coordinator.invalidate(.document)
    await drain()
    XCTAssertEqual(commits, 2)
    XCTAssertEqual(maximumDepth, 1)
  }
  private func drain() async {
    for _ in 0..<10 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(30))
  }
}
