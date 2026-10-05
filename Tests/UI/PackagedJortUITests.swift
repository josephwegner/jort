import XCTest

/// Intentionally separate from normal Debug UI tests. The package lane builds
/// dist/Jort.app first, then this test launches that exact Release bundle.
@MainActor final class PackagedJortUITests: XCTestCase {
  func testLocalReleaseJavaScriptDiscoveryExecutionMergeAndRelaunch() throws {
    continueAfterFailure = false
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundle = repository.appendingPathComponent("dist/Jort.app")
    XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PackagedToolsUI-\(UUID())")
    let app = XCUIApplication(url: bundle)
    app.launchEnvironment["JORT_DATA_DIRECTORY"] = root.path
    app.launch()
    defer { app.terminate() }
    let editor = app.textViews["Jort document"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.click()

    // Settings can list packages whose runtime validation failed. Discover
    // several JavaScript commands in the editor, not just the surviving models.
    for command in ["/now", "/today", "/copy-rich", "/lorem"] {
      editor.typeText(command)
      let completion = app.buttons.matching(
        NSPredicate(format: "label BEGINSWITH %@", command + "  ")
      ).firstMatch
      XCTAssertTrue(
        completion.waitForExistence(timeout: 30), "Missing packaged command: \(command)")
      if command != "/lorem" {
        app.typeKey(.escape, modifierFlags: [])
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey(.delete, modifierFlags: [])
      }
    }
    app.typeKey(.return, modifierFlags: [])
    editor.typeText("1")
    app.typeKey(.return, modifierFlags: .shift)
    let merge = app.buttons["Merge"]
    XCTAssertTrue(merge.waitForExistence(timeout: 30))
    XCTAssertTrue((editor.value as? String ?? "").contains("Lorem ipsum"))
    merge.click()
    let merged = try XCTUnwrap(editor.value as? String)
    XCTAssertTrue(merged.hasPrefix("Lorem ipsum"))
    XCTAssertFalse(merged.contains("/lorem"))
    app.typeKey("s", modifierFlags: .command)
    app.terminate()
    app.launch()
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    let restored = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in editor.value as? String == merged }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
    editor.click()
    editor.typeKey(.end, modifierFlags: .command)
    editor.typeText("\n/now")
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "/now  "))
        .firstMatch.waitForExistence(timeout: 30))
  }
}
