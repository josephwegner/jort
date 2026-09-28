import Foundation
import JortJavaScriptClient
import JortToolContracts

/// The production transport. Each request owns a fresh authenticated XPC
/// connection; cancellation addresses only that request's opaque client handle.
public actor XPCJavaScriptBrokerTransport: JavaScriptBrokerTransport {
  private struct Key: Hashable {
    let invocationID: String
    let generation: String
  }

  private final class CompletionBox: @unchecked Sendable {
    let owner: XPCJavaScriptBrokerTransport
    let key: Key
    let handle: OpaquePointer
    let continuation: CheckedContinuation<ToolExecutionResult, Never>

    init(
      owner: XPCJavaScriptBrokerTransport, key: Key, handle: OpaquePointer,
      continuation: CheckedContinuation<ToolExecutionResult, Never>
    ) {
      self.owner = owner
      self.key = key
      self.handle = handle
      self.continuation = continuation
    }

    func finish(_ result: ToolExecutionResult) {
      Task {
        await owner.complete(
          key: key, handle: handle, result: result, continuation: continuation)
      }
    }
  }

  private var requests: [Key: OpaquePointer] = [:]

  public init() {}

  public func send(_ payload: JavaScriptRequestPayload, operation: JavaScriptOperation) async
    -> ToolExecutionResult
  {
    guard
      let invocation = UUID(uuidString: payload.invocationID),
      let generation = UUID(uuidString: payload.generation),
      let handle = jort_js_client_create()
    else {
      return .init(failure: .init(.internalError, message: "Unable to prepare JavaScript."))
    }

    let key = Key(invocationID: payload.invocationID, generation: payload.generation)
    let nonce = UUID()
    requests[key] = handle

    return await withCheckedContinuation { continuation in
      let completion = CompletionBox(
        owner: self, key: key, handle: handle, continuation: continuation)
      withUUIDBytes(nonce) { nonceBytes in
        withUUIDBytes(invocation) { invocationBytes in
          withUUIDBytes(generation) { generationBytes in
            withDataPointers(
              [payload.contract, payload.source, payload.input, payload.clock, payload.uuid]
            ) { fields in
              var request = JortJSClientRequest()
              request.operation = operation.protocolTag
              request.nonce = nonceBytes
              request.invocation = invocationBytes
              request.generation = generationBytes
              request.deadline_ms = UInt32(payload.deadlineMilliseconds)
              request.output_bytes = UInt32(payload.maximumOutputBytes)
              request.output_lines = UInt32(payload.maximumOutputLines)
              request.contract = fields[0]
              request.contract_length = payload.contract.count
              request.source = fields[1]
              request.source_length = payload.source.count
              request.input = fields[2]
              request.input_length = payload.input.count
              request.clock = fields[3]
              request.clock_length = payload.clock.count
              request.uuid = fields[4]
              request.uuid_length = payload.uuid.count
              jort_js_client_send(handle, &request) {
                status, output, outputLength, error, errorLength in
                let result = Self.result(
                  status: status, output: output, outputLength: outputLength,
                  error: error, errorLength: errorLength)
                completion.finish(result)
              }
            }
          }
        }
      }
    }
  }

  public func cancel(invocationID: String, generation: String) async {
    if let handle = requests[Key(invocationID: invocationID, generation: generation)] {
      jort_js_client_cancel(handle)
    }
  }

  private func complete(
    key: Key, handle: OpaquePointer, result: ToolExecutionResult,
    continuation: CheckedContinuation<ToolExecutionResult, Never>
  ) {
    if requests.removeValue(forKey: key) == handle {
      jort_js_client_release(handle)
    }
    continuation.resume(returning: result)
  }

  nonisolated private static func result(
    status: UInt32, output: UnsafePointer<UInt8>?, outputLength: Int,
    error: UnsafePointer<UInt8>?, errorLength: Int
  ) -> ToolExecutionResult {
    if status == 0 {
      return .init(output: text(output, count: outputLength))
    }
    let code: ToolFailureCode
    switch status {
    case 1: code = .implementation
    case 2: code = .cancelled
    case 3: code = .timeout
    case 4: code = .outputLimit
    case 5: code = .protocolError
    case 6: code = .sandboxBootstrap
    case 7: code = .cpuLimit
    case 8: code = .crash
    case 9: code = .unavailable
    case 10: code = .busy
    case 11: code = .peerIdentity
    case 12: code = .launch
    case 14: code = .engineLimit
    default: code = .internalError
    }
    let message = text(error, count: errorLength)
    return .init(
      failure: .init(
        code, message: message.isEmpty ? "JavaScript worker failed." : message))
  }

  nonisolated private static func text(_ bytes: UnsafePointer<UInt8>?, count: Int) -> String {
    guard let bytes, count > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
  }
}

private func withUUIDBytes<Result>(
  _ value: UUID, _ body: (UnsafePointer<UInt8>) -> Result
) -> Result {
  var bytes = value.uuid
  return withUnsafeBytes(of: &bytes) { body($0.bindMemory(to: UInt8.self).baseAddress!) }
}

private func withDataPointers<Result>(
  _ values: [Data], _ body: ([UnsafePointer<UInt8>?]) -> Result
) -> Result {
  func recurse(_ index: Int, _ pointers: [UnsafePointer<UInt8>?]) -> Result {
    guard index < values.count else { return body(pointers) }
    return values[index].withUnsafeBytes { bytes in
      recurse(index + 1, pointers + [bytes.bindMemory(to: UInt8.self).baseAddress])
    }
  }
  return recurse(0, [])
}
