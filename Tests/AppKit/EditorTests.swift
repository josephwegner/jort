import XCTest
import AppKit
import Darwin
import JortDocument
import JortPersistence
@testable import JortAppKit

@MainActor final class EditorTests: EditorTestCase {
  func testUndoBudgetEvictsWholeGroupsAndKeepsNewestOversizedGroup() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    let history = controller.textView.history
    history.groupLimit = 3
    for _ in 0..<5 {
      insert(
        "x", range: NSRange(location: controller.state.utf16Count, length: 0), into: controller)
    }
    XCTAssertEqual(history.retainedGroupCount, 3)
    history.undo()
    XCTAssertEqual(controller.state.text, "xxxx")
    history.redo()
    XCTAssertEqual(controller.state.text, "xxxxx")
    history.payloadLimit = 1
    history.beginUndoGrouping()
    controller.textView.insertText("a", replacementRange: NSRange(location: 5, length: 0))
    controller.textView.insertText("b", replacementRange: NSRange(location: 6, length: 0))
    history.endUndoGrouping()
    XCTAssertEqual(history.retainedGroupCount, 1)
    XCTAssertGreaterThan(history.retainedPayloadBytes, history.payloadLimit)
    history.undo()
    XCTAssertEqual(controller.state.text, "xxxxx")
    XCTAssertFalse(history.canUndo)
    history.redo()
    XCTAssertEqual(controller.state.text, "xxxxxab")
    history.removeAllActions()
    XCTAssertEqual(history.retainedPayloadBytes, 0)
    XCTAssertEqual(history.retainedGroupCount, 0)
  }

  func testUntrackedServiceReplacementUsesBoundedDiff() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert("first\n日本語\nlast", range: NSRange(location: 0, length: 0), into: controller)
    let revision = controller.state.revision
    let recorder = DocumentWorkRecorder()
    controller.textView.history.beginUndoGrouping()
    DocumentInstrumentation.$recorder.withValue(recorder) {
      controller.textView.textStorage?.replaceCharacters(
        in: NSRange(location: 6, length: 3), with: "🦊")
      controller.textView.didChangeText()
    }
    controller.textView.history.endUndoGrouping()
    XCTAssertEqual(controller.state.text, "first\n🦊\nlast")
    XCTAssertEqual(controller.state.revision, revision + 1)
    XCTAssertNil(recorder.snapshot[.flattenCalls])
    XCTAssertNil(recorder.snapshot[.completeValidations])
    controller.textView.undo(nil)
    XCTAssertEqual(controller.state.text, "first\n日本語\nlast")
  }

  func testOrdinaryNativeCommitDoesNotFlattenDocument() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    var work: [Int] = []
    for count in [1000, 10_000] {
      insert(
        String(repeating: "short line\n", count: count),
        range: NSRange(location: 0, length: controller.state.utf16Count), into: controller)
      let revision = controller.state.revision
      let recorder = DocumentWorkRecorder()
      DocumentInstrumentation.$recorder.withValue(recorder) {
        insert("x", range: NSRange(location: 1, length: 0), into: controller)
      }
      XCTAssertEqual(controller.state.revision, revision + 1)
      XCTAssertNil(recorder.snapshot[.flattenCalls])
      XCTAssertNil(recorder.snapshot[.completeValidations])
      work.append(recorder.snapshot[.visitedLines, default: 0])
    }
    // Native layout is included; ten times more offscreen lines may add index-path
    // work but must not add a scan proportional to the document's line count.
    XCTAssertLessThanOrEqual(work[1], work[0] + 256)
  }

  func testNativeRandomUndoRedoUsesCoordinator() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    XCTAssertNotNil(controller.textView.textLayoutManager)
    var seed: UInt64 = 71
    func next(_ count: Int) -> Int {
      seed = seed &* 6364136223846793005 &+ 1
      return Int(seed >> 32) % count
    }
    for _ in 0..<100 {
      let before = controller.state
      let chars = Array(before.text)
      let position = next(chars.count + 1)
      let offset = String(chars.prefix(position)).utf16.count
      insert(
        ["x", "\n", "🦊", " ", "日本語"][next(5)], range: NSRange(location: offset, length: 0),
        into: controller)
      let after = controller.state
      XCTAssertEqual(after.revision, before.revision + 1)
      controller.textView.undo(nil)
      XCTAssertEqual(controller.state.lines, before.lines)
      XCTAssertEqual(controller.textView.string, before.text)
      controller.textView.redo(nil)
      XCTAssertEqual(controller.state.lines, after.lines)
      XCTAssertEqual(controller.state.revision, before.revision + 3)
      try controller.state.validate()
    }
    let saved = expectation(description: "Latest snapshot saved")
    controller.persistence.flush {
      XCTAssertTrue($0)
      saved.fulfill()
    }
    wait(for: [saved], timeout: 5)
    XCTAssertEqual(controller.coordinator.committedRevision, controller.state.revision)
  }
  func testProgrammaticInsertionPreservesSelectionAndIsUndoable() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert("first\nsecond\nthird", range: NSRange(location: 0, length: 0), into: controller)
    let before = controller.state
    controller.textView.setSelectedRange(NSRange(location: 6, length: 6))
    controller.textView.history.beginUndoGrouping()
    let result = try controller.apply(
      .init(
        baseRevision: before.revision, origin: .automation,
        mutation: .insertAfter(lineID: before.lines[0].id, text: "output")))
    controller.textView.history.endUndoGrouping()
    let selected = (controller.textView.string as NSString).substring(
      with: controller.textView.selectedRange())
    XCTAssertEqual(selected, "second")
    XCTAssertEqual(result.after.revision, before.revision + 1)
    controller.textView.undo(nil)
    XCTAssertEqual(controller.state.text, before.text)
    XCTAssertEqual(controller.state.lines, before.lines)
    XCTAssertThrowsError(
      try controller.apply(
        .init(
          baseRevision: before.revision, origin: .automation,
          mutation: .insertAfter(lineID: before.lines[0].id, text: "stale"))))
  }
  func testReplaceAllAndLargePaste() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert(
      String(repeating: "hello 🦊\n", count: 1000), range: NSRange(location: 0, length: 0),
      into: controller)
    let before = controller.state
    let replacement = before.text.replacingOccurrences(of: "hello", with: "goodbye")
    insert(
      replacement, range: NSRange(location: 0, length: before.text.utf16.count), into: controller)
    try controller.state.validate()
    controller.textView.undo(nil)
    XCTAssertEqual(controller.state.lines, before.lines)
    XCTAssertEqual(controller.state.text, before.text)
  }
  func testLandmarkMutationAndJoinNativeUndo() throws {
    let (controller, window) = try editor()
    defer { window.orderOut(nil) }
    insert("a\nb\nc", range: NSRange(location: 0, length: 0), into: controller)
    let original = controller.state
    let landmark = Landmark(lineID: original.lines[1].id, emoji: "👩🏽‍💻")
    controller.mutateLandmark(.landmark(landmark))
    XCTAssertEqual(controller.textView.string, original.text)
    XCTAssertEqual(controller.state.lines, original.lines)
    controller.textView.undo(nil)
    XCTAssertTrue(controller.state.landmarks.isEmpty)
    controller.textView.redo(nil)
    XCTAssertEqual(controller.state.landmarks, [landmark])
    insert("", range: NSRange(location: 1, length: 1), into: controller)
    XCTAssertEqual(controller.state.landmarks.first?.lineID, original.lines[0].id)
    controller.textView.undo(nil)
    XCTAssertEqual(controller.state.landmarks, [landmark])
    XCTAssertEqual(controller.state.lines, original.lines)
    controller.textView.redo(nil)
    XCTAssertEqual(controller.state.landmarks.first?.lineID, original.lines[0].id)
    XCTAssertEqual(controller.textView.accessibilityValue(), "ab\nc")
    controller.textView.setSelectedRange(NSRange(location: 0, length: 4))
    XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 0, length: 4))
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    XCTAssertTrue(
      controller.textView.writeSelection(
        to: clipboard, types: controller.textView.writablePasteboardTypes))
    XCTAssertEqual(clipboard.string(forType: .string), "ab\nc")
  }
  func testSustainedEditingAutosaveScrollingAndBoundedUndo() async throws {
    let beforeLaunch = ProcessInfo.processInfo.systemUptime
    let (controller, window) = try editor(waitForStartup: false)
    let loaded = expectation(
      for: NSPredicate { _, _ in controller.startupPhase == .ready }, evaluatedWith: nil)
    await fulfillment(of: [loaded], timeout: 5)
    defer { window.orderOut(nil) }
    let launch = ProcessInfo.processInfo.systemUptime - beforeLaunch
    let fixture = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "canvas-10000", withExtension: "txt"))
    let content = try String(contentsOf: fixture, encoding: .utf8)
    insert(content, range: NSRange(location: 0, length: 0), into: controller)
    for position in stride(from: 0, to: 10000, by: 2000) {
      controller.mutateLandmark(
        .landmark(Landmark(lineID: controller.state.lines[position].id, emoji: "🌲")))
    }
    var times: [Double] = [], layout: [Double] = [], navigation: [Double] = []
    var paint: [Double] = [], convergence: [Double] = [], acceptance: [Int64: TimeInterval] = [:]
    controller.textView.onFirstPaint = { revision in
      if let start = acceptance.removeValue(forKey: revision) {
        paint.append(ProcessInfo.processInfo.systemUptime - start)
      }
    }
    controller.presentationCoordinator.onConvergence = { convergence.append($0) }
    for index in 0..<40 {
      let line = controller.state.lines[(index * 97) % 10000]
      let navigationStart = ProcessInfo.processInfo.systemUptime
      controller.textView.setSelectedRange(NSRange(location: line.location, length: 0))
      controller.textView.scrollRangeToVisible(NSRange(location: line.location, length: 0))
      controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
      navigation.append(ProcessInfo.processInfo.systemUptime - navigationStart)
      let begin = ProcessInfo.processInfo.systemUptime
      insert("x", range: NSRange(location: line.location, length: 0), into: controller)
      times.append(ProcessInfo.processInfo.systemUptime - begin)
      acceptance[controller.state.revision] = begin
      let layoutStart = ProcessInfo.processInfo.systemUptime
      controller.scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index * 48)))
      controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
      _ = (controller.scroll.verticalRulerView as? LineRuler)?.visibleRows()
      layout.append(ProcessInfo.processInfo.systemUptime - layoutStart)
      try await Task.sleep(for: .milliseconds(20))
    }
    controller.textView.onFirstPaint = nil
    controller.presentationCoordinator.onConvergence = nil
    XCTAssertGreaterThan(controller.coordinator.committedRevision ?? 0, 0)
    let afterEdits = controller.state
    for _ in 0..<40 { controller.textView.undo(nil) }
    XCTAssertEqual(controller.state.text, content)
    for _ in 0..<40 { controller.textView.redo(nil) }
    XCTAssertEqual(controller.state.lines, afterEdits.lines)
    let saved = expectation(description: "Workflow drains latest save")
    controller.persistence.flush {
      XCTAssertTrue($0)
      saved.fulfill()
    }
    await fulfillment(of: [saved], timeout: 10)
    func p95(_ values: [Double]) -> Double {
      values.sorted()[Int(Double(values.count - 1) * 0.95)] * 1000
    }
    print(
      "PERF native: launch=\(launch * 1000)ms edit p95=\(p95(times))ms navigation p95=\(p95(navigation))ms scroll/gutter p95=\(p95(layout))ms undoGroups=\(controller.textView.history.levelsOfUndo)"
    )

    for (name, values) in [
      ("native-edit", times), ("native-navigation", navigation), ("viewport-layout", layout),
      ("native-first-paint", paint), ("prepared-convergence", convergence),
    ] {
      guard values.count > 5 else {
        XCTFail("Insufficient samples for \(name): \(values.count)")
        continue
      }
      PerformanceDistribution.report(
        name, fixture: "canvas-10000", text: content, samples: values, warmup: 5)
    }
    if ProcessInfo.processInfo.environment["JORT_PERFORMANCE_ENFORCE"] == "1" {
      XCTAssertLessThan(launch, 2)
      XCTAssertLessThan(p95(times), 100)
      XCTAssertLessThan(p95(layout), 100)
    }
  }
}
