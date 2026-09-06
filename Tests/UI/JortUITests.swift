import XCTest

@MainActor final class JortUITests: XCTestCase {
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
}
