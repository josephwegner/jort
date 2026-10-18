import Foundation

/// A test-only bundle marker opts in; normal app launches never write receipts.
/// The UI runner checks this before sending any clicks or keystrokes.
public enum UITestLaunchIsolation {
  public enum Failure: Error { case invalidContext }

  private struct Receipt: Encodable {
    let bundleID: String
    let bundlePath: String
    let executablePath: String
    let storePath: String
    let processID: Int32
    let nonce: String
  }

  public static func recordIfRequested(
    bundle: Bundle = .main,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    directory: URL,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    userHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws {
    let marked = bundle.object(forInfoDictionaryKey: "JortUITestIsolation") as? Bool == true
    let nonce = environment["JORT_UI_TEST_ISOLATION_NONCE"]
    guard marked || nonce != nil else { return }
    let store = directory.resolvingSymlinksInPath().standardizedFileURL
    // The app and XCTest runner have different per-bundle temporary roots.
    // Permit only these specific temporary directories, never container Data
    // generally or the normal application's note directory.
    let runnerTemporary = userHomeDirectory.appendingPathComponent(
      "Library/Containers/dev.jort.uitests.xctrunner/Data/tmp", isDirectory: true)
    let roots = [temporaryDirectory, runnerTemporary]
    let storeComponents = store.path.split(separator: "/")
    // Keep the shared system root literal: Foundation may remap the root URL
    // itself to a process-specific temporary folder, unlike its child URLs.
    let isTemporary =
      store.path.hasPrefix("/private/tmp/")
      || roots.contains { root in
        let components = root.resolvingSymlinksInPath().path.split(separator: "/")
        return storeComponents.count > components.count && storeComponents.starts(with: components)
      }
    guard marked,
      let id = bundle.bundleIdentifier, id.hasPrefix("dev.jort.editor.uitests."),
      let nonce, UUID(uuidString: nonce) != nil,
      let requested = environment["JORT_DATA_DIRECTORY"], requested.hasPrefix("/"),
      URL(fileURLWithPath: requested).resolvingSymlinksInPath().standardizedFileURL == store,
      isTemporary,
      let executable = bundle.executableURL
    else { throw Failure.invalidContext }
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    let receipt = Receipt(
      bundleID: id,
      bundlePath: bundle.bundleURL.resolvingSymlinksInPath().path,
      executablePath: executable.resolvingSymlinksInPath().path,
      storePath: store.path,
      processID: ProcessInfo.processInfo.processIdentifier,
      nonce: nonce)
    try JSONEncoder().encode(receipt).write(
      to: store.appendingPathComponent(".jort-ui-launch.json"), options: .atomic)
  }
}
