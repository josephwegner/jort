import Foundation

/// App-wide external-child admission. Tool dispatch must use `shared` after
/// host authorization; separate instances exist for isolated tests only.
actor ExternalScriptAdmissionController {
  static let shared = ExternalScriptAdmissionController()

  let capacity: Int
  let queueLimit: Int
  private let runner: ExternalScriptRunner
  private var active: Set<UUID> = []
  private struct Waiter {
    let id: UUID
    let deadline: ContinuousClock.Instant
    let continuation: CheckedContinuation<Void, Error>
    let timer: Task<Void, Never>
  }
  private var waiters: [Waiter] = []

  init(capacity: Int = 4, queueLimit: Int = 16, runner: ExternalScriptRunner = .init()) {
    self.capacity = max(1, min(4, capacity))
    self.queueLimit = max(0, min(16, queueLimit))
    self.runner = runner
  }

  var occupancy: (active: Int, queued: Int) { (active.count, waiters.count) }

  func execute(
    plan: ExternalScriptLaunchPlan, payload: Data,
    invocationDeadline: ContinuousClock.Instant
  ) async throws -> String {
    let id = UUID()
    // Accept once: time spent queued must never replenish a call's allowance.
    let deadline = min(invocationDeadline, ContinuousClock.now.advanced(by: runner.limits.timeout))
    return try await withTaskCancellationHandler {
      try await acquire(id: id, deadline: deadline)
      // Runner completion includes direct-child reaping, including cancellation
      // and escalation. The slot is not released when cancellation is requested.
      defer { release(id: id) }
      guard !Task.isCancelled else { throw ExternalScriptRunner.Failure.cancelled }
      return try await runner.run(
        plan: plan, payload: payload, invocationDeadline: invocationDeadline, callDeadline: deadline
      )
    } onCancel: {
      Task { await self.cancelQueued(id: id) }
    }
  }

  private func acquire(id: UUID, deadline: ContinuousClock.Instant) async throws {
    guard !Task.isCancelled else { throw ExternalScriptRunner.Failure.cancelled }
    guard ContinuousClock.now < deadline else { throw ExternalScriptRunner.Failure.timeout }
    if active.count < capacity {
      active.insert(id)
      return
    }
    guard waiters.count < queueLimit else { throw ExternalScriptRunner.Failure.busy }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      // Recheck inside registration: cancellation may race the initial guard.
      guard !Task.isCancelled else {
        continuation.resume(throwing: ExternalScriptRunner.Failure.cancelled)
        return
      }
      let timer = Task { [weak self] in
        do { try await ContinuousClock().sleep(until: deadline) } catch { return }
        await self?.expireQueued(id: id)
      }
      waiters.append(.init(id: id, deadline: deadline, continuation: continuation, timer: timer))
    }
  }

  private func cancelQueued(id: UUID) {
    finishQueued(id: id, failure: .cancelled)
  }

  private func expireQueued(id: UUID) {
    finishQueued(id: id, failure: .timeout)
  }

  private func finishQueued(id: UUID, failure: ExternalScriptRunner.Failure) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.timer.cancel()
    waiter.continuation.resume(throwing: failure)
  }

  private func release(id: UUID) {
    guard active.remove(id) != nil else { return }
    while !waiters.isEmpty {
      let waiter = waiters.removeFirst()
      waiter.timer.cancel()
      guard ContinuousClock.now < waiter.deadline else {
        waiter.continuation.resume(throwing: ExternalScriptRunner.Failure.timeout)
        continue
      }
      active.insert(waiter.id)
      waiter.continuation.resume()
      return
    }
  }
}
