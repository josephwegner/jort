@testable import JortToolRuntime
import Foundation
import XCTest

final class ExternalScriptLaunchPolicyTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ExternalScriptLaunchPolicyTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testPythonUsesFirstDefaultCandidateAndAllowsNonExecutableScript() throws {
    let first = try directory("first")
    let second = try directory("second")
    let firstPython = try file("python3", in: first, executable: true)
    _ = try file("python3", in: second, executable: true)
    let script = try file("tool.PY", executable: false)

    let plan = try policy(searchPaths: [first.path, second.path]).makePlan(scriptPath: script.path)

    XCTAssertEqual(plan.executablePath, firstPython.path)
    XCTAssertEqual(plan.arguments, [script.path])
    XCTAssertEqual(plan.workingDirectoryPath, root.path)
    XCTAssertEqual(plan.environment["PATH"], "\(first.path):\(second.path)")
  }

  func testPythonOverrideIsDirectAndNeverFallsBackToDefaultSearch() throws {
    let search = try directory("search")
    _ = try file("python3", in: search, executable: true)
    let override = try file("venv-python", executable: true)
    let script = try file("tool.py", executable: false)
    let launchPolicy = policy(searchPaths: [search.path])

    XCTAssertEqual(
      try launchPolicy.makePlan(scriptPath: script.path, pythonInterpreterOverride: override.path)
        .executablePath, override.path)
    XCTAssertThrowsError(
      try launchPolicy.makePlan(
        scriptPath: script.path,
        pythonInterpreterOverride: root.appendingPathComponent("missing").path)
    ) { XCTAssertEqual($0 as? ExternalScriptLaunchPolicyError, .missingRuntime) }
  }

  func testEmptyOverrideAndInterpreterSymlinkUsePythonDiscovery() throws {
    let python = try file("actual-python", executable: true)
    let link = root.appendingPathComponent("python3")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: python)
    let script = try file("tool.py", executable: false)
    let plan = try policy(searchPaths: [root.path]).makePlan(
      scriptPath: script.path, pythonInterpreterOverride: "")
    XCTAssertEqual(plan.executablePath, link.path)
  }

  func testRejectsDirectoriesNonExecutableNonPythonAndOversizedPaths() throws {
    let folder = try directory("folder.py")
    let javascript = try file("tool.js", executable: false)
    let launchPolicy = policy(searchPaths: [])
    for path in [folder.path, javascript.path] {
      XCTAssertThrowsError(try launchPolicy.makePlan(scriptPath: path)) {
        XCTAssertEqual($0 as? ExternalScriptLaunchPolicyError, .unsupportedScript)
      }
    }
    XCTAssertThrowsError(
      try launchPolicy.makePlan(scriptPath: "/" + String(repeating: "é", count: 2_048))
    ) { XCTAssertEqual($0 as? ExternalScriptLaunchPolicyError, .invalidPath) }
    XCTAssertThrowsError(
      try launchPolicy.makePlan(scriptPath: root.appendingPathComponent("missing").path)
    ) {
      XCTAssertEqual($0 as? ExternalScriptLaunchPolicyError, .missingScript)
    }
    XCTAssertEqual(
      ExternalScriptLaunchPolicy.defaultSearchPaths.joined(separator: ":"),
      "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
  }

  func testDirectNativeAndShebangPathsDoNotInferInterpreter() throws {
    let native = try file("native", executable: true)
    let shebang = try file("node-script.js", executable: true)
    let launchPolicy = policy(searchPaths: [])

    let nativePlan = try launchPolicy.makePlan(scriptPath: native.path)
    XCTAssertEqual(nativePlan.executablePath, native.path)
    XCTAssertEqual(nativePlan.arguments, [])

    let shebangPlan = try launchPolicy.makePlan(scriptPath: shebang.path)
    XCTAssertEqual(shebangPlan.executablePath, shebang.path)
    XCTAssertEqual(shebangPlan.arguments, [])
  }

  func testPathsAreLiteralAndRejectUnsupportedForms() throws {
    let python = try file("python3", executable: true)
    let metacharacterScript = try file("tool;$(touch nope) 'quoted'.py", executable: false)
    let launchPolicy = policy(searchPaths: [root.path])

    let plan = try launchPolicy.makePlan(scriptPath: metacharacterScript.path)
    XCTAssertEqual(plan.executablePath, python.path)
    XCTAssertEqual(plan.arguments, [metacharacterScript.path])

    for invalid in [
      "relative.py", "~other/tool.py", "file:///tmp/tool.py", "https://example.com/tool.py",
      "/tmp/a\0b",
    ] {
      XCTAssertThrowsError(try launchPolicy.makePlan(scriptPath: invalid), invalid) {
        XCTAssertEqual($0 as? ExternalScriptLaunchPolicyError, .invalidPath)
      }
    }
    XCTAssertThrowsError(
      try launchPolicy.makePlan(
        scriptPath: metacharacterScript.path, pythonInterpreterOverride: "~/venv/bin/python")
    ) { XCTAssertEqual($0 as? ExternalScriptLaunchPolicyError, .invalidInterpreterOverride) }
  }

  func testTildeSymlinkAndEnvironmentAllowlist() throws {
    let home = try directory("home")
    let actual = try file("actual.py", in: home, executable: false)
    let link = home.appendingPathComponent("linked.py")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
    let python = try file("python3", executable: true)
    let launchPolicy = ExternalScriptLaunchPolicy(
      environment: [
        "LANG": "de_DE.UTF-8", "LC_ALL": String(repeating: "x", count: 129),
        "LC_CTYPE": "bad value", "SECRET": "not forwarded",
      ],
      homeDirectoryPath: home.path,
      temporaryDirectoryPath: "/tmp/jort-tests",
      userName: "jort-user",
      searchPaths: [root.path])

    let plan = try launchPolicy.makePlan(scriptPath: "~/linked.py")

    XCTAssertEqual(plan.executablePath, python.path)
    XCTAssertEqual(plan.arguments, [link.path])
    XCTAssertEqual(plan.workingDirectoryPath, home.path)
    XCTAssertEqual(
      plan.environment,
      [
        "PATH": root.path, "HOME": home.path, "TMPDIR": "/tmp/jort-tests",
        "USER": "jort-user", "LOGNAME": "jort-user", "LANG": "de_DE.UTF-8",
      ])
  }

  func testMissingPythonAndDefaultLocaleHaveFixedFailuresAndContext() throws {
    let script = try file("tool.py", executable: false)
    let launchPolicy = policy(searchPaths: [])

    XCTAssertThrowsError(try launchPolicy.makePlan(scriptPath: script.path)) {
      XCTAssertEqual($0 as? ExternalScriptLaunchPolicyError, .missingRuntime)
      XCTAssertEqual(
        $0.localizedDescription, "Install Python or select an absolute Python interpreter.")
    }

    let executable = try file("native", executable: true)
    let plan = try launchPolicy.makePlan(scriptPath: executable.path)
    XCTAssertEqual(plan.environment["LANG"], "en_US.UTF-8")
    XCTAssertNil(plan.environment["LC_ALL"])
    XCTAssertNil(plan.environment["LC_CTYPE"])
  }

  private func policy(searchPaths: [String]) -> ExternalScriptLaunchPolicy {
    .init(
      environment: [:], homeDirectoryPath: root.path, temporaryDirectoryPath: "/tmp/jort-tests",
      userName: "jort-user", searchPaths: searchPaths)
  }

  private func directory(_ name: String) throws -> URL {
    let directory = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @discardableResult
  private func file(_ name: String, in directory: URL? = nil, executable: Bool) throws -> URL {
    let url = (directory ?? root).appendingPathComponent(name)
    try Data("fixture".utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    return url
  }
}
