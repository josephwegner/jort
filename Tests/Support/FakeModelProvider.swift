import Foundation
import JortToolContracts

public actor FakeModelProvider: ModelProvider {
  public enum Behavior: Sendable {
    case success(String), failure(ModelFailure), delayed(String, Duration), late(String, Duration)
  }
  public let behavior: Behavior
  public private(set) var requests: [ModelRequest] = []
  public init(_ behavior: Behavior) { self.behavior = behavior }
  public func execute(_ request: ModelRequest) async throws -> String {
    requests.append(request)
    let output: String
    switch behavior {
    case .success(let text): output = text
    case .failure(let failure): throw failure
    case .delayed(let text, let delay):
      try await Task.sleep(for: delay)
      output = text
    case .late(let text, let delay):
      try? await Task.sleep(for: delay)
      output = text
    }
    return try request.validateOutput(output)
  }
}
