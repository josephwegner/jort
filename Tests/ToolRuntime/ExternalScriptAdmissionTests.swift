import Darwin
import Foundation
import XCTest
@testable import JortToolRuntime

final class ExternalScriptAdmissionTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("JortAdmission-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func script(_ body: String) throws -> ExternalScriptLaunchPlan {
    let file = root.appendingPathComponent(UUID().uuidString)
    try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return try ExternalScriptLaunchPolicy().makePlan(scriptPath: file.path)
  }

  private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  private func waitForOccupancy(
    _ controller: ExternalScriptAdmissionController, active: Int, queued: Int
  ) async -> Bool {
    await waitUntil {
      let occupancy = await controller.occupancy
      return occupancy.active == active && occupancy.queued == queued
    }
  }

  private func failure(
    of operation: () async throws -> String
  ) async -> ExternalScriptRunner.Failure? {
    do {
      _ = try await operation()
      return nil
    } catch {
      return error as? ExternalScriptRunner.Failure
    }
  }

  func testCapacityAndQueueLimitAreClamped() async {
    let defaults = ExternalScriptAdmissionController()
    let defaultCapacity = await defaults.capacity
    let defaultQueueLimit = await defaults.queueLimit
    XCTAssertEqual(defaultCapacity, 4)
    XCTAssertEqual(defaultQueueLimit, 16)

    let minimum = ExternalScriptAdmissionController(capacity: -1, queueLimit: -1)
    let minimumCapacity = await minimum.capacity
    let minimumQueueLimit = await minimum.queueLimit
    XCTAssertEqual(minimumCapacity, 1)
    XCTAssertEqual(minimumQueueLimit, 0)

    let maximum = ExternalScriptAdmissionController(capacity: 99, queueLimit: 99)
    let maximumCapacity = await maximum.capacity
    let maximumQueueLimit = await maximum.queueLimit
    XCTAssertEqual(maximumCapacity, 4)
    XCTAssertEqual(maximumQueueLimit, 16)
  }

  func testQueueFullRejectsWithoutLaunchingAndCancelledCallsLeaveQueue() async throws {
    let launchGate = DispatchSemaphore(value: 0)
    var releasedLaunchGate = false
    defer {
      if !releasedLaunchGate { launchGate.signal() }
    }
    let hookEntered = LockedFlag()
    let runner = ExternalScriptRunner(beforeLaunch: {
      hookEntered.set()
      launchGate.wait()
    })
    let controller = ExternalScriptAdmissionController(capacity: 1, queueLimit: 1, runner: runner)
    let plan = try script("/usr/bin/touch launched")
    let deadline = ContinuousClock().now.advanced(by: .seconds(5))

    let first = Task {
      try await controller.execute(
        plan: plan, payload: Data("{}".utf8), invocationDeadline: deadline)
    }
    let entered = await waitUntil { hookEntered.value }
    XCTAssertTrue(entered, "The first request did not reach beforeLaunch")
    guard entered else { return }

    let second = Task {
      try await controller.execute(
        plan: plan, payload: Data("{}".utf8), invocationDeadline: deadline)
    }
    let queued = await waitForOccupancy(controller, active: 1, queued: 1)
    XCTAssertTrue(queued, "The second request was not queued")
    guard queued else { return }

    let thirdFailure = await failure {
      try await controller.execute(
        plan: plan, payload: Data("{}".utf8), invocationDeadline: deadline)
    }
    XCTAssertEqual(thirdFailure, .busy)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path))

    second.cancel()
    let secondFailure = await failure { try await second.value }
    XCTAssertEqual(secondFailure, .cancelled)
    let dequeued = await waitForOccupancy(controller, active: 1, queued: 0)
    XCTAssertTrue(dequeued, "Cancelling a queued request did not remove it")
    guard dequeued else { return }

    first.cancel()
    releasedLaunchGate = true
    launchGate.signal()
    let firstFailure = await failure { try await first.value }
    XCTAssertEqual(firstFailure, .cancelled)
    let empty = await waitForOccupancy(controller, active: 0, queued: 0)
    XCTAssertTrue(empty, "The active slot was not released after reaping")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path))
  }

  func testQueuedRequestTimesOutWithoutSpawning() async throws {
    let launchGate = DispatchSemaphore(value: 0)
    var releasedLaunchGate = false
    defer {
      if !releasedLaunchGate { launchGate.signal() }
    }
    let hookEntered = LockedFlag()
    var limits = ExternalScriptRunner.Limits()
    limits.timeout = .milliseconds(500)
    let runner = ExternalScriptRunner(
      limits: limits,
      beforeLaunch: {
        hookEntered.set()
        launchGate.wait()
      })
    let controller = ExternalScriptAdmissionController(capacity: 1, queueLimit: 1, runner: runner)
    let activePlan = try script("while :; do :; done")
    let queuedMarker = root.appendingPathComponent("queued-launched")
    let queuedPlan = try script("/usr/bin/touch queued-launched")
    let deadline = ContinuousClock().now.advanced(by: .seconds(5))

    let active = Task {
      try await controller.execute(
        plan: activePlan, payload: Data("{}".utf8), invocationDeadline: deadline)
    }
    let entered = await waitUntil { hookEntered.value }
    XCTAssertTrue(entered, "The active request did not reach beforeLaunch")
    guard entered else { return }

    let queued = Task {
      try await controller.execute(
        plan: queuedPlan, payload: Data("{}".utf8), invocationDeadline: deadline)
    }
    let waiting = await waitForOccupancy(controller, active: 1, queued: 1)
    XCTAssertTrue(waiting, "The request did not enter the admission queue")
    guard waiting else { return }

    let queuedFailure = await failure { try await queued.value }
    XCTAssertEqual(queuedFailure, .timeout)
    XCTAssertFalse(FileManager.default.fileExists(atPath: queuedMarker.path))

    releasedLaunchGate = true
    launchGate.signal()
    let activeFailure = await failure { try await active.value }
    XCTAssertEqual(activeFailure, .timeout)
    let empty = await waitForOccupancy(controller, active: 0, queued: 0)
    XCTAssertTrue(empty, "The active slot was not released")
  }

  func testDequeuedRequestKeepsItsAcceptanceDeadline() async throws {
    let firstGate = DispatchSemaphore(value: 0)
    let secondGate = DispatchSemaphore(value: 0)
    defer {
      firstGate.signal()
      secondGate.signal()
    }
    let firstLaunch = FirstLaunchGate()
    let secondEntered = LockedFlag()
    var limits = ExternalScriptRunner.Limits()
    limits.timeout = .seconds(2)
    let runner = ExternalScriptRunner(
      limits: limits,
      beforeLaunch: {
        if firstLaunch.take() {
          firstGate.wait()
        } else {
          secondEntered.set()
          secondGate.wait()
        }
      })
    let controller = ExternalScriptAdmissionController(capacity: 1, queueLimit: 1, runner: runner)
    let firstPlan = try script("/bin/cat")
    let secondPlan = try script("/usr/bin/touch dequeued-launched")
    let clock = ContinuousClock()
    let invocationDeadline = clock.now.advanced(by: .seconds(10))
    let first = Task {
      try await controller.execute(
        plan: firstPlan, payload: Data("{}".utf8), invocationDeadline: invocationDeadline)
    }
    defer { first.cancel() }
    let reachedFirst = await waitUntil { firstLaunch.entered }
    XCTAssertTrue(reachedFirst)
    guard reachedFirst else { return }
    let second = Task {
      try await controller.execute(
        plan: secondPlan, payload: Data("{}".utf8), invocationDeadline: invocationDeadline)
    }
    defer { second.cancel() }
    let queued = await waitForOccupancy(controller, active: 1, queued: 1)
    XCTAssertTrue(queued)
    guard queued else { return }
    let queueConfirmedAt = clock.now
    // Spend part of the call budget queued, then allow dequeue well before expiry.
    try await clock.sleep(until: queueConfirmedAt.advanced(by: .milliseconds(600)))
    firstGate.signal()
    let firstOutput = try await first.value
    XCTAssertEqual(firstOutput, "{}")
    let reachedSecond = await waitUntil { secondEntered.value }
    XCTAssertTrue(reachedSecond)
    guard reachedSecond else { return }
    // Original deadline is no later than queueConfirmedAt + 2s. A fresh
    // runner budget would last until at least queueConfirmedAt + 2.6s.
    try await clock.sleep(until: queueConfirmedAt.advanced(by: .milliseconds(2_100)))
    secondGate.signal()
    let result = await failure { try await second.value }
    XCTAssertEqual(result, .timeout)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("dequeued-launched").path))
    let empty = await waitForOccupancy(controller, active: 0, queued: 0)
    XCTAssertTrue(empty)
  }

  func testCancelledChildKeepsSlotThroughEscalationAndReaping() async throws {
    var limits = ExternalScriptRunner.Limits()
    limits.terminationGrace = .seconds(2)
    let controller = ExternalScriptAdmissionController(
      capacity: 1, queueLimit: 0, runner: .init(limits: limits))
    let plan = try script("trap '' TERM\nprintf '%s' $$ > pid\nwhile :; do :; done")
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let running = Task {
      try await controller.execute(
        plan: plan, payload: Data("{}".utf8), invocationDeadline: deadline)
    }
    defer { running.cancel() }
    let marker = root.appendingPathComponent("pid")
    let ready = await waitUntil {
      guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return false }
      return Int32(text) != nil
    }
    XCTAssertTrue(ready, "The child did not install its SIGTERM handler")
    let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
    running.cancel()
    let nextFailure = await failure {
      try await controller.execute(
        plan: plan, payload: Data("{}".utf8), invocationDeadline: deadline)
    }
    XCTAssertEqual(nextFailure, .busy, "Cancellation must not free a live child's admission slot")
    let cancelled = await failure { try await running.value }
    XCTAssertEqual(cancelled, .cancelled)
    var status: Int32 = 0
    XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
    XCTAssertEqual(errno, ECHILD)
    let empty = await waitForOccupancy(controller, active: 0, queued: 0)
    XCTAssertTrue(empty)
  }

  func testQueuedRequestsRunInFIFOOrder() async throws {
    let launchGate = DispatchSemaphore(value: 0)
    var releasedLaunchGate = false
    defer {
      if !releasedLaunchGate { launchGate.signal() }
    }
    let firstLaunch = FirstLaunchGate()
    let runner = ExternalScriptRunner(beforeLaunch: {
      if firstLaunch.take() { launchGate.wait() }
    })
    let controller = ExternalScriptAdmissionController(capacity: 1, queueLimit: 3, runner: runner)
    let deadline = ContinuousClock().now.advanced(by: .seconds(5))
    let firstPlan = try script("printf 1 >> order\n/bin/cat")
    let secondPlan = try script("printf 2 >> order\n/bin/cat")
    let thirdPlan = try script("printf 3 >> order\n/bin/cat")

    let first = Task {
      try await controller.execute(
        plan: firstPlan, payload: Data("{}".utf8), invocationDeadline: deadline)
    }
    let entered = await waitUntil { firstLaunch.entered }
    XCTAssertTrue(entered, "The first request did not reach beforeLaunch")
    guard entered else { return }

    let second = Task {
      try await controller.execute(
        plan: secondPlan, payload: Data("{}".utf8), invocationDeadline: deadline)
    }
    let secondQueued = await waitForOccupancy(controller, active: 1, queued: 1)
    XCTAssertTrue(secondQueued, "The second request did not queue")
    guard secondQueued else { return }

    let third = Task {
      try await controller.execute(
        plan: thirdPlan, payload: Data("{}".utf8), invocationDeadline: deadline)
    }
    let thirdQueued = await waitForOccupancy(controller, active: 1, queued: 2)
    XCTAssertTrue(thirdQueued, "The third request did not queue")
    guard thirdQueued else { return }

    releasedLaunchGate = true
    launchGate.signal()
    let firstOutput = try await first.value
    let secondOutput = try await second.value
    let thirdOutput = try await third.value
    XCTAssertEqual(firstOutput, "{}")
    XCTAssertEqual(secondOutput, "{}")
    XCTAssertEqual(thirdOutput, "{}")
    let order = try String(contentsOf: root.appendingPathComponent("order"), encoding: .utf8)
    XCTAssertEqual(order, "123")
    let empty = await waitForOccupancy(controller, active: 0, queued: 0)
    XCTAssertTrue(empty, "All slots should be released after the FIFO work completes")
  }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false

  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func set() {
    lock.lock()
    storage = true
    lock.unlock()
  }
}

private final class FirstLaunchGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isFirst = true
  private var didEnter = false

  var entered: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didEnter
  }

  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard isFirst else { return false }
    isFirst = false
    didEnter = true
    return true
  }
}
