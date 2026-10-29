import Darwin
import Foundation
import XCTest
@testable import JortToolRuntime

final class ExternalScriptRunnerTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("JortRunner-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func script(_ body: String, shebang: Bool = true) throws -> ExternalScriptLaunchPlan {
    let file = root.appendingPathComponent(UUID().uuidString)
    try Data(((shebang ? "#!/bin/sh\n" : "") + body + "\n").utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return try ExternalScriptLaunchPolicy().makePlan(scriptPath: file.path)
  }

  private func run(
    _ plan: ExternalScriptLaunchPlan, payload: Data = Data("{}".utf8),
    limits: ExternalScriptRunner.Limits = .init()
  ) async throws -> String {
    try await ExternalScriptRunner(limits: limits).run(
      plan: plan, payload: payload, invocationDeadline: .now.advanced(by: .seconds(5)))
  }

  private func expect(
    _ expected: ExternalScriptRunner.Failure, plan: ExternalScriptLaunchPlan,
    payload: Data = Data("{}".utf8), limits: ExternalScriptRunner.Limits = .init(),
    file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      _ = try await run(plan, payload: payload, limits: limits)
      XCTFail("Expected bounded failure", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? ExternalScriptRunner.Failure, expected, file: file, line: line)
    }
  }

  func testJSONStdinIsLiteralAndClosesAtEOF() async throws {
    let payload = try JSONSerialization.data(withJSONObject: [
      "text": "`touch nope` $(whoami) ; ' \n 🌲"
    ])
    let result = try await run(script("/bin/cat"), payload: payload)
    XCTAssertEqual(result, String(data: payload, encoding: .utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("nope").path))
  }

  func testEmptyOutputAndStderrAreNotPublished() async throws {
    let result = try await run(script("/bin/cat >/dev/null\nprintf secret >&2"))
    XCTAssertEqual(result, "")
  }

  func testWorkingDirectoryAndMinimalEnvironment() async throws {
    let result = try await run(
      script(
        "/bin/cat >/dev/null\nprintf '%s\\n%s\\n%s' \"$PWD\" \"$PATH\" \"${JORT_TEST_SECRET-unset}\""
      ))
    let lines = result.components(separatedBy: "\n")
    XCTAssertEqual(
      URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
    XCTAssertEqual(lines[1], ExternalScriptLaunchPolicy.defaultSearchPaths.joined(separator: ":"))
    XCTAssertEqual(lines[2], "unset")
  }

  func testLaunchFailureNoShellFallbackAndNonzeroExitDiscardPartialOutput() async throws {
    let missing = ExternalScriptLaunchPlan(
      executablePath: root.appendingPathComponent("missing").path, arguments: [],
      workingDirectoryPath: root.path, environment: [:])
    await expect(.launch, plan: missing)
    await expect(.launch, plan: try script("exit 0", shebang: false))
    await expect(.nonzeroExit, plan: try script("/bin/cat >/dev/null\nprintf partial\nexit 7"))
    await expect(.nonzeroExit, plan: try script("/bin/cat >/dev/null\nkill -KILL $$"))
  }

  func testInvalidEncodingAndOutputBounds() async throws {
    await expect(.invalidEncoding, plan: try script("/bin/cat >/dev/null\nprintf '\\377'"))
    var limits = ExternalScriptRunner.Limits()
    limits.stdoutBytes = 100
    await expect(.outputLimit, plan: try script("/usr/bin/head -c 101 /dev/zero"), limits: limits)
    limits = .init()
    limits.stderrBytes = 100
    await expect(
      .outputLimit, plan: try script("/usr/bin/head -c 101 /dev/zero >&2"), limits: limits)
    limits = .init()
    limits.stdoutLines = 3
    let valid = try await run(script("/bin/cat >/dev/null\nprintf 'a\\r\\nb\\nc'"), limits: limits)
    XCTAssertEqual(valid, "a\r\nb\nc")
    await expect(
      .outputLimit, plan: try script("/bin/cat >/dev/null\nprintf 'a\\nb\\nc\\nd'"), limits: limits)
  }

  func testOutputBeforeReadingLargeStdinDoesNotDeadlock() async throws {
    let payload = Data(("\"" + String(repeating: "x", count: 128 * 1_024) + "\"").utf8)
    let result = try await run(
      script("/usr/bin/head -c 70000 /dev/zero\n/bin/cat"), payload: payload)
    XCTAssertEqual(result.utf8.count, 70_000 + payload.count)
    XCTAssertTrue(result.hasSuffix(String(data: payload, encoding: .utf8)!))
  }

  func testEarlyStdinCloseDoesNotDeliverSIGPIPEToHost() async throws {
    let payload = Data(("\"" + String(repeating: "x", count: 128 * 1_024) + "\"").utf8)
    await expect(.channel, plan: try script("exec 0<&-\n/bin/sleep 0.05"), payload: payload)
  }

  func testInvalidAndOversizedInputDoNotLaunch() async throws {
    let plan = try script("/usr/bin/touch launched")
    await expect(.invalidPayload, plan: plan, payload: Data("not json".utf8))
    await expect(.invalidPayload, plan: plan, payload: Data([0xff]))
    await expect(.invalidPayload, plan: plan, payload: Data(repeating: 32, count: 256 * 1_024 + 1))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path))
  }

  func testDeadlineTerminatesAndReapsChildIgnoringSIGTERM() async throws {
    var limits = ExternalScriptRunner.Limits()
    limits.timeout = .milliseconds(150)
    limits.terminationGrace = .milliseconds(30)
    let plan = try script("trap '' TERM\nprintf '%s' $$ > pid\nwhile :; do :; done")
    await expect(.timeout, plan: plan, limits: limits)
    let pid = try XCTUnwrap(
      Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
    var status: Int32 = 0
    XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
    XCTAssertEqual(errno, ECHILD)
  }

  func testCancellationTerminatesAndReapsRunningChild() async throws {
    let plan = try script("printf '%s' $$ > pid\nwhile :; do :; done")
    let runner = ExternalScriptRunner()
    let task = Task {
      try await runner.run(
        plan: plan, payload: Data("{}".utf8), invocationDeadline: .now.advanced(by: .seconds(5)))
    }
    let marker = root.appendingPathComponent("pid")
    for _ in 0..<100 {
      if FileManager.default.fileExists(atPath: marker.path) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertEqual(error as? ExternalScriptRunner.Failure, .cancelled) }
    let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
    var status: Int32 = 0
    XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
    XCTAssertEqual(errno, ECHILD)
  }

  func testExpiredInvocationDoesNotLaunchAndRetainedDescendantPipeIsBounded() async throws {
    let plan = try script("/usr/bin/touch launched")
    do {
      _ = try await ExternalScriptRunner().run(
        plan: plan, payload: Data("{}".utf8), invocationDeadline: .now)
      XCTFail("Expected timeout")
    } catch { XCTAssertEqual(error as? ExternalScriptRunner.Failure, .timeout) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path))
    var limits = ExternalScriptRunner.Limits()
    limits.collectionGrace = .milliseconds(20)
    await expect(
      .channel, plan: try script("/bin/cat >/dev/null\n/bin/sleep 0.2 &\nexit 0"), limits: limits)
    // The legitimate descendant is not a cleanup target; let the short fixture finish naturally.
    try await Task.sleep(for: .milliseconds(250))
  }

  func testCancellationBeforeLaunchDoesNotLaunch() async throws {
    let reachedBeforeLaunch = expectation(description: "reached before launch")
    let launchGate = DispatchSemaphore(value: 0)
    var releasedLaunchGate = false
    defer {
      if !releasedLaunchGate { launchGate.signal() }
    }
    let marker = root.appendingPathComponent("launched")
    let plan = try script("/usr/bin/touch launched")
    let runner = ExternalScriptRunner(beforeLaunch: {
      reachedBeforeLaunch.fulfill()
      launchGate.wait()
    })
    let task = Task {
      try await runner.run(
        plan: plan, payload: Data("{}".utf8), invocationDeadline: .now.advanced(by: .seconds(5)))
    }

    await fulfillment(of: [reachedBeforeLaunch], timeout: 1)
    task.cancel()
    releasedLaunchGate = true
    launchGate.signal()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertEqual(error as? ExternalScriptRunner.Failure, .cancelled) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testDeadlineExpiringBeforeLaunchDoesNotLaunch() async throws {
    let reachedBeforeLaunch = expectation(description: "reached before launch")
    let launchGate = DispatchSemaphore(value: 0)
    var releasedLaunchGate = false
    defer {
      if !releasedLaunchGate { launchGate.signal() }
    }
    let marker = root.appendingPathComponent("launched")
    let runner = ExternalScriptRunner(beforeLaunch: {
      reachedBeforeLaunch.fulfill()
      launchGate.wait()
    })
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    let plan = try script("/usr/bin/touch launched")
    let task = Task {
      try await runner.run(plan: plan, payload: Data("{}".utf8), invocationDeadline: deadline)
    }

    await fulfillment(of: [reachedBeforeLaunch], timeout: 1)
    try await clock.sleep(until: deadline)
    releasedLaunchGate = true
    launchGate.signal()
    do {
      _ = try await task.value
      XCTFail("Expected timeout")
    } catch { XCTAssertEqual(error as? ExternalScriptRunner.Failure, .timeout) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testDuplicateForChildNormalizesDescriptor() throws {
    guard fcntl(STDIN_FILENO, F_GETFD) != -1 else {
      throw XCTSkip("Standard input is closed")
    }

    var duplicate: FileHandle? = try ExternalScriptRunner.duplicateForChild(STDIN_FILENO)
    defer { duplicate?.closeFile() }
    let descriptor = try XCTUnwrap(duplicate?.fileDescriptor)
    XCTAssertGreaterThan(descriptor, 2)
    let flags = fcntl(descriptor, F_GETFD)
    XCTAssertNotEqual(flags, -1)
    XCTAssertNotEqual(flags & FD_CLOEXEC, 0)
    duplicate?.closeFile()
    duplicate = nil
    XCTAssertNotEqual(fcntl(STDIN_FILENO, F_GETFD), -1)
  }

  func testRunnerDoesNotInheritUnmarkedDescriptor() async throws {
    let file = root.appendingPathComponent("inherited-descriptor")
    let source = Darwin.open(file.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
    guard source >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
    defer { Darwin.close(source) }
    let descriptor = fcntl(source, F_DUPFD, 100)
    guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
    defer { Darwin.close(descriptor) }
    let flags = fcntl(descriptor, F_GETFD)
    XCTAssertNotEqual(flags, -1)
    XCTAssertEqual(fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC), 0)

    let result = try await run(
      script("if [ -e /dev/fd/\(descriptor) ]; then exit 91; fi\n/bin/cat"))
    XCTAssertEqual(result, "{}")
  }
}
