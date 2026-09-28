import CryptoKit
import Darwin
import Foundation
import JortToolContracts
import JortToolRuntime

/// Test-only parity transport. It launches the same one-run worker product
/// directly and speaks the bounded child protocol; no QuickJS code is linked
/// into the XCTest process.
final class WorkerProcessJavaScriptTransport: JavaScriptBrokerTransport, @unchecked Sendable {
  private struct Key: Hashable {
    let invocation: String
    let generation: String
  }

  private let lock = NSLock()
  private var processes: [Key: Process] = [:]

  func send(_ request: JavaScriptRequestPayload, operation: JavaScriptOperation) async
    -> ToolExecutionResult
  {
    await run(request, operation: operation)
  }

  private func run(_ request: JavaScriptRequestPayload, operation: JavaScriptOperation) async
    -> ToolExecutionResult
  {
    guard
      let invocation = UUID(uuidString: request.invocationID),
      let generation = UUID(uuidString: request.generation)
    else { return failure(.protocolError) }
    let key = Key(invocation: request.invocationID, generation: request.generation)
    let nonce = UUID()
    let fields = [
      request.contract, request.source, request.input, request.clock, request.uuid, Data(),
    ]
    let frame = Self.requestFrame(
      operation: operation, nonce: nonce, invocation: invocation, generation: generation,
      request: request, fields: fields)
    let process = Process()
    process.executableURL = Self.workerURL
    process.arguments = ["1", String(request.deadlineMilliseconds)]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return failure(.launch) }
    lock.withLock { processes[key] = process }
    defer { lock.withLock { processes.removeValue(forKey: key) } }

    guard
      let ready = try? Self.readExactly(24, from: output.fileHandleForReading),
      ready.count == 24, ready.prefix(8) == Data([74, 74, 82, 49, 0, 1, 0, 1]),
      Self.uint32(ready, 8) == 0
    else {
      process.terminate()
      process.waitUntilExit()
      return failure(.sandboxBootstrap)
    }
    do {
      try input.fileHandleForWriting.write(contentsOf: frame)
      try input.fileHandleForWriting.close()
    } catch {
      process.terminate()
      process.waitUntilExit()
      return failure(.protocolError)
    }
    let response = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      return failure(process.terminationStatus == SIGXCPU ? .cpuLimit : .crash)
    }
    return Self.parse(
      response, nonce: nonce, invocation: invocation, generation: generation,
      maximumOutputBytes: request.maximumOutputBytes)
  }

  func cancel(invocationID: String, generation: String) async {
    let process = lock.withLock {
      processes[Key(invocation: invocationID, generation: generation)]
    }
    process?.terminate()
  }

  private static var workerURL: URL {
    Bundle(for: WorkerProcessJavaScriptTransport.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("JortJavaScriptTestOracle")
  }

  private static func requestFrame(
    operation: JavaScriptOperation, nonce: UUID, invocation: UUID, generation: UUID,
    request: JavaScriptRequestPayload, fields: [Data]
  ) -> Data {
    var header = Data(repeating: 0, count: 128)
    header.replaceSubrange(0..<4, with: Data("JJS1".utf8))
    header[5] = 1
    header[7] = 1
    put(operation.protocolTag, in: &header, at: 8)
    let nonceBytes = data(nonce), invocationBytes = data(invocation),
      generationBytes = data(generation)
    header.replaceSubrange(12..<28, with: nonceBytes)
    header.replaceSubrange(28..<44, with: invocationBytes)
    header.replaceSubrange(44..<52, with: generationBytes.prefix(8))
    header.replaceSubrange(88..<96, with: generationBytes.suffix(8))
    put(UInt32(request.deadlineMilliseconds), in: &header, at: 52)
    put(UInt32(request.maximumOutputBytes), in: &header, at: 56)
    put(UInt32(request.maximumOutputLines), in: &header, at: 60)
    for (index, field) in fields.enumerated() {
      put(UInt32(field.count), in: &header, at: 64 + 4 * index)
    }
    let payload = fields.reduce(into: Data()) { $0.append($1) }
    header.replaceSubrange(96..<128, with: Data(SHA256.hash(data: payload)))
    return header + payload
  }

  private static func parse(
    _ frame: Data, nonce: UUID, invocation: UUID, generation: UUID, maximumOutputBytes: Int
  ) -> ToolExecutionResult {
    guard frame.count >= 128, frame.prefix(4) == Data("JJS1".utf8), frame[5] == 1, frame[7] == 2,
      frame.subdata(in: 12..<28) == data(nonce), frame.subdata(in: 28..<44) == data(invocation),
      frame.subdata(in: 44..<52) + frame.subdata(in: 88..<96) == data(generation)
    else { return failure(.protocolError) }
    let status = uint32(frame, 8)
    let lengths = (0..<6).map { Int(uint32(frame, 64 + 4 * $0)) }
    guard lengths.dropFirst(2).allSatisfy({ $0 == 0 }), lengths[0] <= maximumOutputBytes,
      lengths[1] <= 512, 128 + lengths.reduce(0, +) == frame.count
    else { return failure(.protocolError) }
    let payload = frame.dropFirst(128)
    guard Data(SHA256.hash(data: payload)) == frame.subdata(in: 96..<128) else {
      return failure(.protocolError)
    }
    let output = Data(payload.prefix(lengths[0]))
    let error = Data(payload.dropFirst(lengths[0]).prefix(lengths[1]))
    guard let outputText = String(data: output, encoding: .utf8),
      let errorText = String(data: error, encoding: .utf8),
      !output.contains(0), !error.contains(0), status <= 14,
      status == 0 ? error.isEmpty : output.isEmpty && !error.isEmpty
    else { return failure(.protocolError) }
    if status == 0 { return .init(output: outputText) }
    return .init(failure: .init(failureCode(status), message: errorText))
  }

  private static func failureCode(_ status: UInt32) -> ToolFailureCode {
    switch status {
    case 1: .implementation
    case 2: .cancelled
    case 3: .timeout
    case 4: .outputLimit
    case 5: .protocolError
    case 6: .sandboxBootstrap
    case 7: .cpuLimit
    case 8: .crash
    case 9: .unavailable
    case 10: .busy
    case 11: .peerIdentity
    case 12: .launch
    case 14: .engineLimit
    default: .internalError
    }
  }

  private static func failure(_ code: ToolFailureCode) -> ToolExecutionResult {
    .init(failure: .init(code, message: "JavaScript worker failed: \(code.rawValue)."))
  }

  private func failure(_ code: ToolFailureCode) -> ToolExecutionResult { Self.failure(code) }

  private static func data(_ uuid: UUID) -> Data {
    var value = uuid.uuid
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  private static func put(_ value: UInt32, in data: inout Data, at offset: Int) {
    data[offset] = UInt8(truncatingIfNeeded: value >> 24)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
    data[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
    data[offset + 3] = UInt8(truncatingIfNeeded: value)
  }

  private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
    (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
      | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
  }

  private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
    var result = Data()
    while result.count < count {
      guard let next = try handle.read(upToCount: count - result.count), !next.isEmpty else {
        break
      }
      result.append(next)
    }
    return result
  }
}

extension JavaScriptBrokerClient {
  static let testWorker = JavaScriptBrokerClient(transport: WorkerProcessJavaScriptTransport())
}

extension ToolRuntime {
  static func testExecute(
    _ package: ToolPackage, input: ToolExecutionInput, timeout: TimeInterval = 5,
    validationOnly: Bool = false,
    identity: InvocationGeneration = .init(invocationID: UUID(), generation: UUID())
  ) async -> ToolExecutionResult {
    await execute(
      package, input: input, timeout: timeout, validationOnly: validationOnly,
      client: .testWorker, identity: identity)
  }
}
