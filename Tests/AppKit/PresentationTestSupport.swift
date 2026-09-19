import AppKit
import XCTest
@testable import JortAppKit

@MainActor func settlePresentation(
  _ editor: EditorViewController, file: StaticString = #filePath, line: UInt = #line
) {
  let done = XCTNSPredicateExpectation(
    predicate: NSPredicate { _, _ in
      MainActor.assumeIsolated {
        let state = editor.presentationCoordinator.state
        return !state.scheduled && !state.reconciling
      }
    }, object: nil)
  XCTAssertEqual(
    XCTWaiter.wait(for: [done], timeout: 2), .completed,
    "Presentation did not converge: \(editor.presentationCoordinator.state)", file: file, line: line
  )
}

@MainActor func settlePresentationAsync(
  _ editor: EditorViewController, file: StaticString = #filePath, line: UInt = #line
) async {
  for _ in 0..<200 {
    let state = editor.presentationCoordinator.state
    if !state.scheduled && !state.reconciling { return }
    try? await Task.sleep(for: .milliseconds(10))
  }
  XCTFail(
    "Presentation did not converge: \(editor.presentationCoordinator.state)", file: file, line: line
  )
}
