import Foundation
import JortJavaScript

import JortToolContracts

private final class ToolCancellation: @unchecked Sendable {
  // The C token uses atomics; ownership extends through the detached execution.
  let pointer: OpaquePointer
  init?() {
    guard let pointer = jort_js_cancellation_new() else { return nil }
    self.pointer = pointer
  }
  func cancel() { jort_js_cancel(pointer) }
  deinit { jort_js_cancellation_free(pointer) }
}

public enum ToolRuntime {
  public static func validate(_ package: ToolPackage) throws {
    try package.validate()
    guard package.manifest.executorType == .javascript else { return }
    if let error = jort_js_validate(package.source) {
      jort_js_free(error)
      throw ToolPackageError.invalidSource
    }
  }

  public static func execute(
    _ package: ToolPackage, input: ToolExecutionInput,
    timeout: TimeInterval = 5, validationOnly: Bool = false
  ) async -> ToolExecutionResult {
    do { try package.validate() } catch {
      return .init(failure: .init(.invalidPackage, message: "Invalid tool package."))
    }
    guard package.manifest.executorType == .javascript else {
      return .init(error: "Model tools require the model executor.")
    }
    guard input.content.utf8.count <= package.manifest.maximumInputBytes else {
      return .init(failure: .init(.invalidInput, message: "Input exceeds the tool limit."))
    }
    guard let token = ToolCancellation(), let data = try? JSONEncoder().encode(input),
      let json = String(data: data, encoding: .utf8)
    else { return .init(error: "Unable to capture input.") }
    return await withTaskCancellationHandler {
      await Task.detached {
        var status: Int32 = 1
        guard
          let bytes = jort_js_run(
            package.source, json, validationOnly ? "validate" : "default", 16 * 1024 * 1024,
            min(30, max(0.01, timeout)), package.manifest.maximumOutputBytes * 6 + 4096,
            token.pointer, &status)
        else { return ToolExecutionResult(error: "Runtime allocation failed.") }
        defer { jort_js_free(bytes) }
        if status == 2 { return .init(failure: .init(.cancelled, message: "Cancelled.")) }
        if status == 3 { return .init(failure: .init(.timeout, message: "Tool timed out.")) }
        guard status == 0,
          let result = try? JSONDecoder().decode(
            ToolExecutionResult.self,
            from: Data(String(cString: bytes).utf8)),
          (result.output == nil) != (result.error == nil)
        else {
          return .init(error: "JavaScript failed or returned an invalid result.")
        }
        if let error = result.error { return .init(error: String(error.prefix(512))) }
        let output = result.output!
        var lines = 1, previousCR = false
        for unit in output.utf16 {
          if unit == 10 && !previousCR || [13, 0x85, 0x2028, 0x2029].contains(unit) { lines += 1 }
          previousCR = unit == 13
          if lines > package.manifest.maximumOutputLines { break }
        }
        guard output.utf8.count <= package.manifest.maximumOutputBytes,
          lines <= package.manifest.maximumOutputLines
        else {
          return .init(failure: .init(.outputLimit, message: "Output exceeds the tool limit."))
        }
        return result
      }.value
    } onCancel: {
      token.cancel()
    }
  }
}

public struct RuntimePackageValidator: ToolPackageValidator {
  public init() {}
  public func validatePackage(_ package: ToolPackage) async throws {
    try await Task.detached { try ToolRuntime.validate(package) }.value
  }
}
