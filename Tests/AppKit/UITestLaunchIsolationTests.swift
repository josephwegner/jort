import Foundation
import XCTest
@testable import JortAppKit

final class UITestLaunchIsolationTests: XCTestCase {
  private func fixture(
    id: String, marked: Bool,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) throws -> (URL, Bundle) {
    let root = temporaryDirectory.appendingPathComponent(
      "UIIsolation-\(UUID())")
    let app = root.appendingPathComponent("Fixture.app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try Data().write(to: macOS.appendingPathComponent("Jort"))
    let info: [String: Any] = [
      "CFBundleIdentifier": id, "CFBundleExecutable": "Jort", "CFBundlePackageType": "APPL",
      "JortUITestIsolation": marked,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (root, try XCTUnwrap(Bundle(url: app)))
  }

  func testOrdinaryProductionLaunchDoesNotWriteAReceipt() throws {
    let (root, bundle) = try fixture(id: "dev.jort.editor", marked: false)
    let store = root.appendingPathComponent("store")
    try UITestLaunchIsolation.recordIfRequested(bundle: bundle, environment: [:], directory: store)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
  }

  func testTestEnvironmentCannotOpenProductionIdentity() throws {
    let (root, bundle) = try fixture(id: "dev.jort.editor", marked: false)
    let store = root.appendingPathComponent("store")
    XCTAssertThrowsError(
      try UITestLaunchIsolation.recordIfRequested(
        bundle: bundle,
        environment: [
          "JORT_UI_TEST_ISOLATION_NONCE": UUID().uuidString, "JORT_DATA_DIRECTORY": store.path,
        ],
        directory: store))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
  }

  func testMarkedProductionIdentityStillFailsClosed() throws {
    let (root, bundle) = try fixture(id: "dev.jort.editor", marked: true)
    let store = root.appendingPathComponent("store")
    XCTAssertThrowsError(
      try UITestLaunchIsolation.recordIfRequested(
        bundle: bundle,
        environment: [
          "JORT_UI_TEST_ISOLATION_NONCE": UUID().uuidString, "JORT_DATA_DIRECTORY": store.path,
        ],
        directory: store))
  }

  func testIsolatedIdentityRequiresNonceAndMatchingTemporaryStore() throws {
    let (root, bundle) = try fixture(id: "dev.jort.editor.uitests.debug.fixture", marked: true)
    let store = root.appendingPathComponent("store")
    for environment in [
      ["JORT_DATA_DIRECTORY": store.path],
      ["JORT_UI_TEST_ISOLATION_NONCE": "bad", "JORT_DATA_DIRECTORY": store.path],
      ["JORT_UI_TEST_ISOLATION_NONCE": UUID().uuidString, "JORT_DATA_DIRECTORY": root.path],
    ] {
      XCTAssertThrowsError(
        try UITestLaunchIsolation.recordIfRequested(
          bundle: bundle, environment: environment, directory: store))
    }
    XCTAssertThrowsError(
      try UITestLaunchIsolation.recordIfRequested(
        bundle: bundle,
        environment: [
          "JORT_UI_TEST_ISOLATION_NONCE": UUID().uuidString, "JORT_DATA_DIRECTORY": store.path,
        ],
        directory: store, temporaryDirectory: root.appendingPathComponent("Allowed")))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
  }

  func testReceiptReportsActualIdentityExecutableStorePIDAndNonce() throws {
    let (root, bundle) = try fixture(id: "dev.jort.editor.uitests.packaged.fixture", marked: true)
    let store = root.appendingPathComponent("store"), nonce = UUID().uuidString
    try UITestLaunchIsolation.recordIfRequested(
      bundle: bundle,
      environment: ["JORT_UI_TEST_ISOLATION_NONCE": nonce, "JORT_DATA_DIRECTORY": store.path],
      directory: store)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: store.appendingPathComponent(".jort-ui-launch.json")))
        as? [String: Any])
    XCTAssertEqual(object["bundleID"] as? String, bundle.bundleIdentifier)
    XCTAssertEqual(object["bundlePath"] as? String, bundle.bundleURL.resolvingSymlinksInPath().path)
    XCTAssertEqual(
      object["executablePath"] as? String, bundle.executableURL?.resolvingSymlinksInPath().path)
    XCTAssertEqual(object["storePath"] as? String, store.resolvingSymlinksInPath().path)
    XCTAssertEqual(object["processID"] as? Int32, ProcessInfo.processInfo.processIdentifier)
    XCTAssertEqual(object["nonce"] as? String, nonce)
  }

  func testSharedTemporaryStoreSurvivesPerAppTemporaryDirectoryChange() throws {
    let shared = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    let (root, bundle) = try fixture(
      id: "dev.jort.editor.uitests.debug.fixture", marked: true, temporaryDirectory: shared)
    let perAppTemporary = root.appendingPathComponent("PerAppTemporary")
    let store = root.appendingPathComponent("store")
    func record(_ directory: URL) throws {
      try UITestLaunchIsolation.recordIfRequested(
        bundle: bundle,
        environment: [
          "JORT_UI_TEST_ISOLATION_NONCE": UUID().uuidString,
          "JORT_DATA_DIRECTORY": directory.path,
        ], directory: directory, temporaryDirectory: perAppTemporary)
    }
    try record(store)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: store.appendingPathComponent(".jort-ui-launch.json").path))
    XCTAssertThrowsError(try record(shared))
    let link = root.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Library")
    XCTAssertThrowsError(try record(link))
  }

  func testRunnerTemporaryStoreIsAllowedButContainerDataIsNot() throws {
    let (home, bundle) = try fixture(id: "dev.jort.editor.uitests.debug.fixture", marked: true)
    let data = home.appendingPathComponent("Library/Containers/dev.jort.uitests.xctrunner/Data")
    let store = data.appendingPathComponent("tmp/notes")
    func record(_ directory: URL) throws {
      try UITestLaunchIsolation.recordIfRequested(
        bundle: bundle,
        environment: [
          "JORT_UI_TEST_ISOLATION_NONCE": UUID().uuidString,
          "JORT_DATA_DIRECTORY": directory.path,
        ], directory: directory, temporaryDirectory: home.appendingPathComponent("PerAppTmp"),
        userHomeDirectory: home)
    }
    try record(store)
    XCTAssertThrowsError(try record(data))
    XCTAssertThrowsError(try record(data.appendingPathComponent("tmp")))
    XCTAssertThrowsError(try record(data.appendingPathComponent("Documents")))
  }
}
