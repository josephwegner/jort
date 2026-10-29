import Darwin
import Foundation

/// Internal transport primitive, not an authorization or tool-dispatch entry point.
struct ExternalScriptRunner: Sendable {
  struct Limits: Sendable {
    var inputBytes = 256 * 1_024
    var stdoutBytes = 1_024 * 1_024
    var stdoutLines = 100_000
    var stderrBytes = 64 * 1_024
    var timeout: Duration = .seconds(30)
    var terminationGrace: Duration = .milliseconds(500)
    var collectionGrace: Duration = .milliseconds(500)
  }

  enum Failure: Error, Sendable, Equatable {
    case invalidPayload, launch, nonzeroExit, invalidEncoding, outputLimit
    case timeout, cancelled, channel, busy
  }

  let limits: Limits
  private let beforeLaunch: (@Sendable () -> Void)?

  init(limits: Limits = .init(), beforeLaunch: (@Sendable () -> Void)? = nil) {
    self.limits = limits
    self.beforeLaunch = beforeLaunch
  }

  func run(
    plan: ExternalScriptLaunchPlan, payload: Data,
    invocationDeadline: ContinuousClock.Instant,
    callDeadline: ContinuousClock.Instant? = nil
  ) async throws -> String {
    let cancellation = Cancellation()
    let localDeadline = ContinuousClock.now.advanced(by: limits.timeout)
    let deadline = min(min(invocationDeadline, callDeadline ?? localDeadline), localDeadline)
    return try await withTaskCancellationHandler {
      guard !Task.isCancelled else { throw Failure.cancelled }
      return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            continuation.resume(
              returning: try collect(
                plan: plan, payload: payload, deadline: deadline, cancellation: cancellation))
          } catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    var isCancelled: Bool { lock.withLock { value } }

    func launch<T>(before deadline: ContinuousClock.Instant, _ operation: () -> T) throws -> T {
      try lock.withLock {
        guard !value else { throw Failure.cancelled }
        guard ContinuousClock.now < deadline else { throw Failure.timeout }
        // This lock is the launch boundary. Cancellation that wins it first
        // prevents spawning; once spawning starts, cancellation owns cleanup,
        // not rollback. Keep the lock through the syscall, never through I/O.
        return operation()
      }
    }
  }

  /// Duplicate without assuming that inherited standard descriptors are open.
  /// The source remains caller-owned; the returned handle owns only its duplicate.
  static func duplicateForChild(_ descriptor: Int32) throws -> FileHandle {
    let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
    guard duplicate >= 0 else { throw Failure.channel }
    return FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
  }

  private static func makePipe() throws -> (
    fileHandleForReading: FileHandle, fileHandleForWriting: FileHandle
  ) {
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    return (
      try duplicateForChild(pipe.fileHandleForReading.fileDescriptor),
      try duplicateForChild(pipe.fileHandleForWriting.fileDescriptor)
    )
  }

  private func collect(
    plan: ExternalScriptLaunchPlan, payload: Data, deadline: ContinuousClock.Instant,
    cancellation: Cancellation
  ) throws -> String {
    guard payload.count <= limits.inputBytes,
      String(data: payload, encoding: .utf8) != nil,
      (try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])) != nil
    else { throw Failure.invalidPayload }
    guard !cancellation.isCancelled else { throw Failure.cancelled }
    guard ContinuousClock.now < deadline else { throw Failure.timeout }

    let input = try Self.makePipe()
    let output = try Self.makePipe()
    let errors = try Self.makePipe()
    let inputHandle = input.fileHandleForWriting
    let outputHandle = output.fileHandleForReading
    let errorHandle = errors.fileHandleForReading
    let inputFD = inputHandle.fileDescriptor
    let outputFD = outputHandle.fileDescriptor
    let errorFD = errorHandle.fileDescriptor
    // Child endpoints are also closed on setup/launch failure.
    defer {
      try? input.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
      try? errors.fileHandleForWriting.close()
    }
    var inputOpen = true, outputOpen = true, errorOpen = true
    func closeInput() {
      if inputOpen {
        inputOpen = false
        try? inputHandle.close()
      }
    }
    func closeOutput() {
      if outputOpen {
        outputOpen = false
        try? outputHandle.close()
      }
    }
    func closeErrors() {
      if errorOpen {
        errorOpen = false
        try? errorHandle.close()
      }
    }
    defer {
      closeInput()
      closeOutput()
      closeErrors()
    }
    for fd in [inputFD, outputFD, errorFD] {
      let flags = fcntl(fd, F_GETFL)
      guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw Failure.channel
      }
    }
    // Suppress SIGPIPE on this descriptor, never process-wide: a child may close stdin early.
    guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.channel }
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.launch }
    defer { posix_spawn_file_actions_destroy(&actions) }
    let childFDs = [
      input.fileHandleForReading.fileDescriptor,
      output.fileHandleForWriting.fileDescriptor, errors.fileHandleForWriting.fileDescriptor,
    ]
    let allFDs = childFDs + [inputFD, outputFD, errorFD]
    for (source, destination) in zip(childFDs, [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]) {
      guard posix_spawn_file_actions_adddup2(&actions, source, destination) == 0 else {
        throw Failure.launch
      }
    }
    for fd in allFDs {
      guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw Failure.launch }
    }
    guard posix_spawn_file_actions_addchdir_np(&actions, plan.workingDirectoryPath) == 0 else {
      throw Failure.launch
    }
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.launch }
    defer { posix_spawnattr_destroy(&attributes) }
    // Do not pass app connections or unrelated pipe endpoints into the child.
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
      throw Failure.launch
    }
    var argv = ([plan.executablePath] + plan.arguments).map { strdup($0) } + [nil]
    var envp =
      plan.environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [
        nil
      ]
    defer {
      for value in argv { free(value) }
      for value in envp { free(value) }
    }
    guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil })
    else {
      throw Failure.launch
    }
    beforeLaunch?()
    var pid: pid_t = 0
    let launchStatus = try cancellation.launch(before: deadline) {
      argv.withUnsafeMutableBufferPointer { arguments in
        envp.withUnsafeMutableBufferPointer { environment in
          posix_spawn(
            &pid, plan.executablePath, &actions, &attributes, arguments.baseAddress!,
            environment.baseAddress!)
        }
      }
    }
    guard launchStatus == 0 else { throw Failure.launch }
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    try? errors.fileHandleForWriting.close()

    // This thread alone owns waitpid and signals; PID reuse cannot occur before reaping.
    var reaped = false
    var exitStatus: Int32 = 0
    var failure: Failure?
    var killAt: ContinuousClock.Instant?
    var collectionEnds: ContinuousClock.Instant?
    var killed = false
    var written = 0
    var stdout = Data()
    var stderrBytes = 0
    var lines = 1
    var previousByte: UInt8 = 0
    var penultimateByte: UInt8 = 0
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)

    func fail(_ reason: Failure) {
      guard failure == nil else { return }
      failure = reason
      closeInput()
      closeOutput()
      closeErrors()
      if !reaped {
        _ = Darwin.kill(pid, SIGTERM)
        killAt = ContinuousClock.now.advanced(by: limits.terminationGrace)
      }
    }

    while true {
      let now = ContinuousClock.now
      if !reaped {
        let result = waitpid(pid, &exitStatus, WNOHANG)
        if result == pid {
          reaped = true
        } else if result < 0 && errno != EINTR {
          // ECHILD means ownership is already lost: never signal a possibly reused PID.
          reaped = true
          fail(.channel)
        }
      }
      if cancellation.isCancelled { fail(.cancelled) }
      if now >= deadline { fail(.timeout) }
      if failure != nil {
        if reaped { break }
        if let killAt, now >= killAt, !killed {
          killed = true
          _ = Darwin.kill(pid, SIGKILL)
        }
        // Cleanup retains ownership until reaped; arbitrary OS failure has no hard bound.
        Thread.sleep(forTimeInterval: 0.005)
        continue
      }

      if reaped {
        closeInput()
        if collectionEnds == nil {
          collectionEnds = min(deadline, now.advanced(by: limits.collectionGrace))
        }
        if !outputOpen && !errorOpen { break }
        if let collectionEnds, now >= collectionEnds {
          fail(.channel)
          continue
        }
      }

      if inputOpen && written == payload.count { closeInput() }
      var descriptors = [
        pollfd(fd: inputOpen ? inputFD : -1, events: Int16(POLLOUT), revents: 0),
        pollfd(fd: outputOpen ? outputFD : -1, events: Int16(POLLIN), revents: 0),
        pollfd(fd: errorOpen ? errorFD : -1, events: Int16(POLLIN), revents: 0),
      ]
      let ready = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, 3, 5) }
      if ready < 0 {
        if errno == EINTR { continue }
        fail(.channel)
        continue
      }
      if inputOpen && descriptors[0].revents != 0 {
        let amount = payload.withUnsafeBytes { bytes in
          Darwin.write(inputFD, bytes.baseAddress!.advanced(by: written), payload.count - written)
        }
        if amount > 0 {
          written += amount
        } else if amount < 0 && errno != EAGAIN && errno != EINTR {
          fail(.channel)
        }
      }
      for index in 1...2 where failure == nil {
        guard descriptors[index].revents != 0 else { continue }
        let fd = index == 1 ? outputFD : errorFD
        // A bounded turn per stream preserves cancellation/deadline fairness during floods.
        for _ in 0..<4 {
          let amount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
          if amount == 0 {
            if index == 1 { closeOutput() } else { closeErrors() }
            break
          }
          if amount < 0 {
            if errno != EAGAIN && errno != EINTR { fail(.channel) }
            break
          }
          if index == 1 {
            guard amount <= limits.stdoutBytes - stdout.count else {
              fail(.outputLimit)
              break
            }
            // Count protocol separators incrementally, including split UTF-8 sequences.
            for byte in buffer.prefix(amount) {
              if byte == 10 && previousByte != 13 || byte == 13
                || byte == 0x85 && previousByte == 0xC2
                || (byte == 0xA8 || byte == 0xA9) && previousByte == 0x80 && penultimateByte == 0xE2
              {
                lines += 1
              }
              penultimateByte = previousByte
              previousByte = byte
              if lines > limits.stdoutLines {
                fail(.outputLimit)
                break
              }
            }
            if failure != nil { break }
            stdout.append(contentsOf: buffer.prefix(amount))
          } else {
            guard amount <= limits.stderrBytes - stderrBytes else {
              fail(.outputLimit)
              break
            }
            stderrBytes += amount
          }
        }
      }
    }
    if let failure { throw failure }
    guard !cancellation.isCancelled else { throw Failure.cancelled }
    guard ContinuousClock.now < deadline else { throw Failure.timeout }
    guard written == payload.count else { throw Failure.channel }
    guard exitStatus == 0 else { throw Failure.nonzeroExit }
    guard let text = String(data: stdout, encoding: .utf8) else { throw Failure.invalidEncoding }
    return text
  }
}
