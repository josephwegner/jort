import XCTest

@MainActor final class JortUITests: XCTestCase {
    func testShellOptionRevealAndPocket() throws {
        let app = XCUIApplication()
        app.launchEnvironment["JORT_DATA_DIRECTORY"] = FileManager.default.temporaryDirectory.appendingPathComponent("ShellUI-\(UUID())").path
        app.launch(); defer { app.terminate() }
        let editor = app.textViews["Jort document"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); editor.typeText("First thought\nSecond thought")
        let status = app.buttons["Landmarks"]
        XCTAssertTrue(status.exists)
        XCUIElement.perform(withKeyModifiers: .option) {
            editor.typeKey(.leftArrow, modifierFlags: .option)
            XCTAssertTrue((status.value as? String ?? "").contains("Option held"))
        }
        XCTAssertTrue((status.value as? String ?? "").contains("Line numbers"))
        XCTAssertEqual(editor.value as? String, "First thought\nSecond thought")
        app.buttons["Open Pocket"].click()
        XCTAssertTrue(app.searchFields["Search actions"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["Queue"].exists)
        XCTAssertFalse(app.buttons["Ask Jort"].exists)
        let shot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = "Editor shell"; attachment.lifetime = .keepAlways; add(attachment)
        try shot.pngRepresentation.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("jort-shell-window.png"))
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
        app.buttons["Done"].click()
        editor.click()
        app.typeKey(.end, modifierFlags: .command)
        editor.typeText("!")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertFalse((editor.value as? String ?? "").hasSuffix("!"))
        // Wait on our own recovery file rather than routine save UI or fixed sleeps.
        let durable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let manifestData = try? Data(contentsOf: root.appendingPathComponent("Store/Recovery-manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  let entries = manifest["entries"] as? [[String: Any]], let slot = entries.first?["slot"] as? Int,
                  let data = try? Data(contentsOf: root.appendingPathComponent("Store/Recovery-\(slot).json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let document = json["document"] as? [String: Any] else { return false }
            return (document["content"] as? String) == "Local accessibility test\n\nA second thought."
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [durable], timeout: 5), .completed)
        app.terminate(); app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Local accessibility test\n\nA second thought.")
        app.terminate()
    }
    func testWalkPaletteAndLandmarkKeyboardFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["JORT_DATA_DIRECTORY"] = FileManager.default.temporaryDirectory.appendingPathComponent("WalkUI-\(UUID())").path
        app.launch(); defer { app.terminate() }
        let editor = app.textViews["Jort document"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.click(); editor.typeText("First\nSecond")
        app.typeKey("k", modifierFlags: .command)
        let query = app.searchFields["Search actions"]
        XCTAssertTrue(query.waitForExistence(timeout: 3)); query.typeText("next landmark")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(editor.value as? String, "First\nSecond")
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(query.waitForExistence(timeout: 3)); query.typeText("no such action")
        XCTAssertTrue(app.staticTexts["Matching actions"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        editor.typeText("!"); XCTAssertEqual(editor.value as? String, "First\nSecond!")
    }

    func testSettingsWindowAndCustomToolDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsUI-\(UUID())")
        let app = XCUIApplication(); app.launchEnvironment["JORT_DATA_DIRECTORY"] = root.path
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.textViews["Jort document"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["Jort Settings"].waitForExistence(timeout: 3))
        app.buttons["New Tool"].click()
        let name = app.textFields["Tool name"], command = app.textFields["Command name"], source = app.textViews["JavaScript source"]
        XCTAssertTrue(name.waitForExistence(timeout: 2)); name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("UI Tool")
        command.click(); command.typeKey("a", modifierFlags: .command); command.typeText("9 bad")
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        command.typeKey("a", modifierFlags: .command); command.typeText("ui-tool")
        source.click(); source.typeText("return input;")
        XCTAssertTrue(app.buttons["Save"].isEnabled); app.buttons["Save"].click()
        XCTAssertTrue(app.staticTexts["UI Tool"].waitForExistence(timeout: 3))
        app.windows["Jort Settings"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.textViews["Jort document"].exists)
    }
}
