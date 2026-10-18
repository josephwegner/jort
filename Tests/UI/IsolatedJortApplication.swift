import AppKit
import XCTest

@MainActor enum IsolatedJortApplication {
  enum Failure: Error { case invalidConfiguration, mismatchedLaunch }
  // XCTest's runner is sandboxed. Its own temporary directory is writable
  // across launches; the copied app explicitly permits this test-only root.
  static var temporaryDirectory: URL { FileManager.default.temporaryDirectory }

  static func isTemporaryStore(_ directory: URL) -> Bool {
    let root = temporaryDirectory.resolvingSymlinksInPath().path.split(separator: "/")
    let path = directory.resolvingSymlinksInPath().path.split(separator: "/")
    return path.count > root.count && path.starts(with: root)
  }

  static func make(directory: URL) throws -> XCUIApplication {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["JORT_UI_TEST_APP_PATH"], path.hasPrefix("/"),
      let id = environment["JORT_UI_TEST_APP_ID"], id.hasPrefix("dev.jort.editor.uitests."),
      let bundle = Bundle(url: URL(fileURLWithPath: path)), bundle.bundleIdentifier == id,
      bundle.object(forInfoDictionaryKey: "JortUITestIsolation") as? Bool == true,
      isTemporaryStore(directory)
    else { throw Failure.invalidConfiguration }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let app = XCUIApplication(url: bundle.bundleURL)
    app.launchEnvironment["JORT_DATA_DIRECTORY"] = directory.path
    return app
  }
}

extension XCUIApplication {
  @MainActor func launchIsolated() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["JORT_UI_TEST_APP_PATH"],
      let id = environment["JORT_UI_TEST_APP_ID"], id.hasPrefix("dev.jort.editor.uitests."),
      let store = launchEnvironment["JORT_DATA_DIRECTORY"],
      let bundle = Bundle(url: URL(fileURLWithPath: path)), bundle.bundleIdentifier == id,
      bundle.object(forInfoDictionaryKey: "JortUITestIsolation") as? Bool == true,
      let executable = bundle.executableURL
    else { throw IsolatedJortApplication.Failure.invalidConfiguration }
    let directory = URL(fileURLWithPath: store).resolvingSymlinksInPath()
    guard
      IsolatedJortApplication.isTemporaryStore(directory)
    else { throw IsolatedJortApplication.Failure.invalidConfiguration }
    let nonce = UUID().uuidString
    launchEnvironment["JORT_UI_TEST_ISOLATION_NONCE"] = nonce
    launch()

    struct Receipt: Decodable {
      let bundleID: String
      let bundlePath: String
      let executablePath: String
      let storePath: String
      let processID: Int32
      let nonce: String
    }
    let expectedBundle = bundle.bundleURL.resolvingSymlinksInPath().path
    let expectedExecutable = executable.resolvingSymlinksInPath().path
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        guard
          let data = try? Data(
            contentsOf: directory.appendingPathComponent(".jort-ui-launch.json")),
          let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
          receipt.bundleID == id, receipt.bundlePath == expectedBundle,
          receipt.executablePath == expectedExecutable, receipt.storePath == directory.path,
          receipt.nonce == nonce
        else { return false }
        return MainActor.assumeIsolated {
          let applications = NSRunningApplication.runningApplications(withBundleIdentifier: id)
          return applications.count == 1
            && applications.first.map {
              $0.processIdentifier == receipt.processID
                && $0.bundleURL?.resolvingSymlinksInPath().path == expectedBundle
                && $0.executableURL?.resolvingSymlinksInPath().path == expectedExecutable
            } == true
        }
      }, object: nil)
    guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed else {
      terminate()
      throw IsolatedJortApplication.Failure.mismatchedLaunch
    }
  }
}
