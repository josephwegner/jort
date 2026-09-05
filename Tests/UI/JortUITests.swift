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
            guard let data = try? Data(contentsOf: root.appendingPathComponent("Store/Recovery.json")),
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
}
