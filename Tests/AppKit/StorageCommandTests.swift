import AppKit
import XCTest
import JortDocument
import JortPersistence
@testable import JortAppKit

@MainActor final class StorageCommandTests: EditorTestCase {
  func testCommandSDispatchesImmediateSaveWithAutosaveDelayed() async throws {
    _ = NSApplication.shared
    let store = StartupLoadStore()
    let persistence = PersistenceController(store: store, autosaveDelay: 3600)
    let controller = EditorViewController(persistence: persistence)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    defer {
      window.close()
      window.contentViewController = nil
    }
    window.makeKeyAndOrderFront(nil)
    let menu = NSMenu(title: "File")
    controller.addStorageCommands(to: menu)
    let save = try XCTUnwrap(menu.items.first { $0.keyEquivalent == "s" })
    XCTAssertFalse(controller.validateMenuItem(save))
    let ready = expectation(description: "ready")
    controller.onStartupPhase = { if $0 == .ready { ready.fulfill() } }
    await store.resolve(.success(DocumentSnapshot()))
    await fulfillment(of: [ready], timeout: 5)
    controller.onStartupPhase = nil
    window.makeFirstResponder(controller.textView)
    insert("explicit command", range: NSRange(location: 0, length: 0), into: controller)
    XCTAssertTrue(controller.validateMenuItem(save))
    XCTAssertTrue(save.accessibilityHelp()?.contains(String(controller.state.revision)) == true)
    let before = await store.writes
    XCTAssertTrue(before.isEmpty)
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "s",
        charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
    XCTAssertTrue(menu.performKeyEquivalent(with: event))
    await store.waitForSave()
    let writes = await store.writes
    XCTAssertEqual(writes.last, controller.state)
    XCTAssertTrue(window.firstResponder === controller.textView)
  }
  func testPurgeConfirmationCancelPreservesHistoryAndCurrentText() async throws {
    let (controller, window) = try editor(waitForStartup: false)
    let ready = expectation(
      for: NSPredicate { _, _ in controller.startupPhase == .ready }, evaluatedWith: nil)
    await fulfillment(of: [ready], timeout: 5)
    insert("keep me", range: NSRange(location: 0, length: 0), into: controller)
    let saved = expectation(description: "saved")
    controller.persistence.saveImmediately { _ in saved.fulfill() }
    await fulfillment(of: [saved], timeout: 5)
    let history = try await controller.persistence.openHistory()
    let before = try await history.revisions(before: nil, limit: 100)
    controller.clearHistoryAndRecoveryData()
    let sheet = try XCTUnwrap(window.attachedSheet)
    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    await Task.yield()
    XCTAssertNil(controller.persistence.purgePhase)
    let after = try await history.revisions(before: nil, limit: 100)
    XCTAssertEqual(after, before)
    XCTAssertEqual(controller.state.text, "keep me")
  }
  func testStorageCommandsStayOutOfPocketAndAreValidated() throws {
    let (controller, _) = try editor()
    let menu = NSMenu(title: "File")
    controller.addStorageCommands(to: menu)
    XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.count, 5)
    let clear = try XCTUnwrap(
      menu.items.first { $0.action == #selector(EditorViewController.clearHistoryAndRecoveryData) })
    XCTAssertTrue(controller.validateMenuItem(clear))
    let retry = try XCTUnwrap(
      menu.items.first { $0.action == #selector(EditorViewController.retryStorageCleanup) })
    XCTAssertFalse(controller.validateMenuItem(retry))
    controller.showCommandPalette()
    XCTAssertFalse(
      controller.paletteActions().contains {
        $0.id.contains("recovery") || $0.id.contains("purge") || $0.id == "app.save"
      })
  }
}
