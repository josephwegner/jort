import Foundation

public protocol OpenRouterTransport: Sendable {
  func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data
}

private final class FixedOriginDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public struct BoundedOpenRouterTransport: OpenRouterTransport {
  public init() {}
  public func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
    guard request.url?.scheme == "https", request.url?.host == "openrouter.ai",
      request.url?.port == nil, request.url?.user == nil, request.url?.password == nil,
      ["/api/v1/chat/completions", "/api/v1/auth/keys", "/api/v1/key"].contains(
        request.url?.path ?? ""),
      (1...8_388_608).contains(maximumBytes)
    else { throw ModelFailure.malformed }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 90
    config.httpCookieStorage = nil
    config.urlCache = nil
    config.httpShouldSetCookies = false
    let session = URLSession(
      configuration: config, delegate: FixedOriginDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let response = response as? HTTPURLResponse else { throw ModelFailure.malformed }
      if [401, 403].contains(response.statusCode) { throw ModelFailure.authentication }
      guard (200..<300).contains(response.statusCode) else { throw ModelFailure.malformed }
      guard response.expectedContentLength <= maximumBytes else { throw ModelFailure.limit }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < maximumBytes else { throw ModelFailure.limit }
        data.append(byte)
      }
      return data
    } catch let failure as ModelFailure { throw failure } catch is CancellationError {
      throw ModelFailure.cancelled
    } catch let error as URLError {
      if error.code == .cancelled { throw ModelFailure.cancelled }
      if error.code == .timedOut { throw ModelFailure.timeout }
      throw ModelFailure.offline
    } catch { throw ModelFailure.offline }
  }
}

public struct OpenRouterProvider: ModelProvider {
  private let credentials: any ModelCredentialStore
  private let transport: any OpenRouterTransport
  public init(
    credentials: any ModelCredentialStore,
    transport: any OpenRouterTransport = BoundedOpenRouterTransport()
  ) {
    self.credentials = credentials
    self.transport = transport
  }
  public func execute(_ request: ModelRequest) async throws -> String {
    guard let key = try await credentials.read() else { throw ModelFailure.disconnected }
    var http = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
    http.httpMethod = "POST"
    http.timeoutInterval = 60
    http.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.setValue("Jort", forHTTPHeaderField: "X-Title")
    http.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": request.modelID, "stream": false, "max_tokens": request.maximumTokens,
      "messages": [
        ["role": "system", "content": request.instructions],
        ["role": "user", "content": request.content],
      ],
    ])
    let data = try await transport.send(
      http, maximumBytes: min(8_388_608, request.maximumBytes * 6 + 65_536))
    return try Self.decode(data, request: request)
  }
  private static func noToolCalls(_ value: Any?) -> Bool {
    value == nil || value is NSNull || (value as? [Any])?.isEmpty == true
  }
  public static func decode(_ data: Data, request: ModelRequest) throws -> String {
    guard data.count <= min(8_388_608, request.maximumBytes * 6 + 65_536),
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      value["error"] == nil,
      let choices = value["choices"] as? [[String: Any]], choices.count == 1,
      let choice = choices.first, choice["finish_reason"] as? String == "stop",
      choice["delta"] == nil,
      let message = choice["message"] as? [String: Any], noToolCalls(message["tool_calls"]),
      message["function_call"] == nil || message["function_call"] is NSNull,
      let output = message["content"] as? String,
      let usage = value["usage"] as? [String: Any], let tokens = usage["completion_tokens"] as? Int,
      (0...request.maximumTokens).contains(tokens)
    else { throw ModelFailure.malformed }
    return try request.validateOutput(output)
  }
}
