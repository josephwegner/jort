import XCTest

@MainActor final class JortUITests: XCTestCase {
  func testShellOptionRevealAndPocket() throws {
    let app = XCUIApplication()
    app.launchEnvironment["JORT_DATA_DIRECTORY"] =
      FileManager.default.temporaryDirectory.appendingPathComponent("ShellUI-\(UUID())").path
    app.launch()
    defer { app.terminate() }
    let editor = app.textViews["Jort document"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.click()
    editor.typeText("First thought\nSecond thought")
    let status = app.buttons["Landmarks"]
    XCTAssertTrue(status.exists)
    XCUIElement.perform(withKeyModifiers: .option) {
      editor.typeKey(.leftArrow, modifierFlags: .option)
      XCTAssertTrue((status.value as? String ?? "").contains("Option held"))
    }
    let optionReleased = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        (status.value as? String ?? "").contains("Line numbers")
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [optionReleased], timeout: 2), .completed)
    XCTAssertEqual(editor.value as? String, "First thought\nSecond thought")
    app.buttons["Open Pocket"].click()
    XCTAssertTrue(app.searchFields["Search actions"].waitForExistence(timeout: 3))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(app.buttons["Queue"].exists)
    XCTAssertFalse(app.buttons["Ask Jort"].exists)
    let shot = app.windows.firstMatch.screenshot()
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = "Editor shell"
    attachment.lifetime = .keepAlways
    add(attachment)
    try shot.pngRepresentation.write(
      to: FileManager.default.temporaryDirectory.appendingPathComponent("jort-shell-window.png"))
  }
  func testKeyboardFindUndoAndRelaunchInIsolatedStore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("JortUITest-\(UUID())")
    let app = XCUIApplication()
    app.launchEnvironment["JORT_DATA_DIRECTORY"] = root.path
    app.launch()
    let editor = app.textViews["Jort document"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.click()
    editor.typeText("Local accessibility test\n\nA second thought.")
    XCTAssertEqual(app.windows.firstMatch.title, "Jort")
    app.typeKey("f", modifierFlags: .command)
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 3))
    search.typeText("thought")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(search.exists)
    editor.click()
    app.typeKey(.end, modifierFlags: .command)
    editor.typeText("!")
    app.typeKey("z", modifierFlags: .command)
    XCTAssertFalse((editor.value as? String ?? "").hasSuffix("!"))
    // Wait on our own recovery file rather than routine save UI or fixed sleeps.
    let durable = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        guard
          let manifestData = try? Data(
            contentsOf: root.appendingPathComponent("Store/Recovery-manifest.json")),
          let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
          let entries = manifest["entries"] as? [[String: Any]],
          let slot = entries.first?["slot"] as? Int,
          let data = try? Data(
            contentsOf: root.appendingPathComponent("Store/Recovery-\(slot).json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let document = json["document"] as? [String: Any]
        else { return false }
        return (document["content"] as? String) == "Local accessibility test\n\nA second thought."
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [durable], timeout: 5), .completed)
    app.terminate()
    app.launch()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.value as? String, "Local accessibility test\n\nA second thought.")
    app.terminate()
  }
  func testWalkPaletteAndLandmarkKeyboardFlow() throws {
    let app = XCUIApplication()
    app.launchEnvironment["JORT_DATA_DIRECTORY"] =
      FileManager.default.temporaryDirectory.appendingPathComponent("WalkUI-\(UUID())").path
    app.launch()
    defer { app.terminate() }
    let editor = app.textViews["Jort document"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.click()
    editor.typeText("First\nSecond")
    app.typeKey("k", modifierFlags: .command)
    let query = app.searchFields["Search actions"]
    XCTAssertTrue(query.waitForExistence(timeout: 3))
    query.typeText("next landmark")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertEqual(editor.value as? String, "First\nSecond")
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(query.waitForExistence(timeout: 3))
    query.typeText("no such action")
    XCTAssertTrue(app.staticTexts["Matching actions"].waitForExistence(timeout: 2))
    app.typeKey(.escape, modifierFlags: [])
    editor.typeText("!")
    XCTAssertEqual(editor.value as? String, "First\nSecond!")
  }

  func testSettingsWindowAndCustomToolDraft() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsUI-\(UUID())")
    let app = XCUIApplication()
    app.launchEnvironment["JORT_DATA_DIRECTORY"] = root.path
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.textViews["Jort document"].waitForExistence(timeout: 5))
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(app.windows["Jort Settings"].waitForExistence(timeout: 3))
    app.buttons["New Tool"].click()
    let name = app.textFields["Tool name"], command = app.textFields["Command name"],
      source = app.textViews["JavaScript source"]
    XCTAssertTrue(name.waitForExistence(timeout: 2))
    name.click()
    name.typeKey("a", modifierFlags: .command)
    name.typeText("UI Tool")
    command.click()
    command.typeKey("a", modifierFlags: .command)
    command.typeText("9 bad")
    XCTAssertFalse(app.buttons["Save"].isEnabled)
    command.typeKey("a", modifierFlags: .command)
    command.typeText("ui-tool")
    source.click()
    source.typeKey("a", modifierFlags: .command)
    source.typeText("export default async function(input) { return {output: input.content}; }")
    XCTAssertTrue(app.buttons["Save"].isEnabled)
    app.buttons["Save"].click()
    XCTAssertTrue(app.staticTexts["UI Tool"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.sheets.count, 0)
    let enabled = app.checkBoxes["Enabled"]
    XCTAssertTrue(enabled.exists)
    XCTAssertTrue(enabled.isHittable)
    enabled.click()
    XCTAssertTrue(app.buttons["Save"].isEnabled)
    app.buttons["Save"].click()
    XCTAssertTrue(
      app.staticTexts["Tool saved. Saving does not run it."].waitForExistence(timeout: 3))
    enabled.click()
    XCTAssertTrue(app.buttons["Save"].isEnabled)
    app.buttons["Save"].click()
    app.windows["Jort Settings"].buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(app.textViews["Jort document"].exists)
    let document = app.textViews["Jort document"]
    document.click()
    document.typeText("/ui-tool")
    XCTAssertTrue(app.buttons["/ui-tool  UI Tool"].waitForExistence(timeout: 3))
    app.typeKey(.return, modifierFlags: [])
    XCTAssertEqual(document.value as? String, "/ui-tool ")
    document.typeText("hello")
    app.typeKey(.return, modifierFlags: .shift)
    XCTAssertTrue(app.buttons["Merge"].waitForExistence(timeout: 5))
  }

  func testBundledToolCompletionPendingMergeAndRelaunch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolsUI-\(UUID())")
    let app = XCUIApplication()
    app.launchEnvironment["JORT_DATA_DIRECTORY"] = root.path
    app.launch()
    defer { app.terminate() }
    let editor = app.textViews["Jort document"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.click()
    editor.typeText("I need /calc")
    XCTAssertTrue(app.buttons["/calc  Calc"].waitForExistence(timeout: 3))
    editor.typeText(" 3+3 ")
    app.typeKey(.return, modifierFlags: .shift)
    let merge = app.buttons["Merge"]
    XCTAssertTrue(merge.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.value as? String, "I need /calc 3+3 6")
    XCTAssertTrue(merge.isHittable)
    merge.hover()
    XCTAssertTrue(app.buttons["Dismiss"].isHittable)
    app.buttons["Dismiss"].hover()
    merge.click()
    XCTAssertEqual(editor.value as? String, "I need 6")
    app.typeKey("s", modifierFlags: .command)
    let durable = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        guard
          let data = try? Data(
            contentsOf: root.appendingPathComponent("Store/Recovery-manifest.json")),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let entries = manifest["entries"] as? [[String: Any]],
          let slot = entries.first?["slot"] as? Int,
          let recovery = try? Data(
            contentsOf: root.appendingPathComponent("Store/Recovery-\(slot).json")),
          let envelope = try? JSONSerialization.jsonObject(with: recovery) as? [String: Any],
          let document = envelope["document"] as? [String: Any]
        else { return false }
        return document["content"] as? String == "I need 6"
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [durable], timeout: 5), .completed)
    app.terminate()
    app.launch()
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    XCTAssertEqual(editor.value as? String, "I need 6")
  }
  func testModelsSettingsAndBundledModelDiscovery() throws {
    let app = XCUIApplication()
    app.launchEnvironment["JORT_DATA_DIRECTORY"] =
      FileManager.default.temporaryDirectory.appendingPathComponent("ModelUI-\(UUID())").path
    app.launch()
    defer { app.terminate() }
    let editor = app.textViews["Jort document"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.click()
    editor.typeText("/ask")
    XCTAssertTrue(app.buttons["/ask  Ask"].waitForExistence(timeout: 3))
    app.typeKey(.escape, modifierFlags: [])
    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["Jort Settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 3))
    app.staticTexts["Models"].firstMatch.click()
    XCTAssertTrue(app.buttons["Manage OpenRouter Account"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.secureTextFields.firstMatch.exists)
    let shot = settings.screenshot()
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = "Models Settings"
    attachment.lifetime = .keepAlways
    add(attachment)
    try shot.pngRepresentation.write(
      to: FileManager.default.temporaryDirectory.appendingPathComponent("jort-models-settings.png"))
    app.staticTexts["Tools"].firstMatch.click()
    XCTAssertTrue(app.buttons["New Tool"].waitForExistence(timeout: 3))
    settings.buttons[XCUIIdentifierCloseWindow].click()
  }

}
