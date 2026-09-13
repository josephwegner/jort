import Foundation
import CryptoKit
import Security
import Darwin

public struct PKCEAttempt: Sendable {
    public let verifier: String
    public let nonce: String
    public let expiresAt: Date
    public init(now: Date = Date()) throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ModelFailure.authorization }
            return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        verifier = try random(); nonce = try random(); expiresAt = now.addingTimeInterval(180)
    }
    public var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public func authorizationURL(port: UInt16) -> URL {
        var url = URLComponents(string: "https://openrouter.ai/auth")!
        url.queryItems = [.init(name: "callback_url", value: "http://localhost:\(port)/callback/\(nonce)"),
                          .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")]
        return url.url!
    }
    public func code(from target: String, now: Date = Date()) throws -> String {
        guard now < expiresAt, target.utf8.count <= 8192, target.hasPrefix("/callback/\(nonce)?"),
              let url = URLComponents(string: target), url.path == "/callback/\(nonce)",
              let items = url.queryItems, items.count == 1, items[0].name == "code",
              let code = items[0].value, !code.isEmpty, code.utf8.count <= 4096,
              !code.contains("\0") else { throw ModelFailure.authorization }
        return code
    }
}

/// A temporary IPv4 loopback socket. Its only accepted route contains a random,
/// per-attempt nonce. One response closes the socket; cancellation polls at 100 ms.
public final class LoopbackOAuthCallback: @unchecked Sendable {
    public let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var consumed = false
    public init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ModelFailure.authorization }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw ModelFailure.authorization }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard status == 0 else { close(fd); throw ModelFailure.authorization }
        descriptor = fd; port = UInt16(bigEndian: address.sin_port)
    }
    deinit { close(descriptor) }
    private func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if consumed { return false }; consumed = true; return true }
    public func receive(_ attempt: PKCEAttempt) async throws -> String {
        guard claim() else { throw ModelFailure.authorization }
        let job = Task.detached { [self] in
            defer { shutdown(descriptor, SHUT_RDWR) }
            while Date() < attempt.expiresAt {
                try Task.checkCancellation()
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, 100) > 0 else { continue }
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { continue }
                defer { close(client) }
                var noSignal: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var data = Data(); let deadline = min(attempt.expiresAt, Date().addingTimeInterval(2))
                while data.count < 8192 && Date() < deadline {
                    try Task.checkCancellation()
                    var event = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                    guard poll(&event, 1, 100) > 0 else { continue }
                    var buffer = [UInt8](repeating: 0, count: min(1024, 8192 - data.count))
                    let count = recv(client, &buffer, buffer.count, 0)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                    if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
                }
                guard let request = String(data: data, encoding: .utf8), request.contains("\r\n\r\n"),
                      let line = request.components(separatedBy: "\r\n").first else { continue }
                let parts = line.split(separator: " ")
                guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
                      let code = try? attempt.code(from: String(parts[1])) else { continue }
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: 38\r\n\r\nReturn to Jort to finish connecting.\r\n"
                response.withCString { _ = send(client, $0, strlen($0), 0) }
                return code
            }
            throw ModelFailure.timeout
        }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}

public enum ModelConnectionState: String, Codable, Sendable { case notConnected, connecting, connected, unableToVerify, needsAttention }
public struct ModelConnectionStatus: Codable, Equatable, Sendable {
    public var state: ModelConnectionState = .notConnected
    public var lastVerified: Date?
    public var expiration: Date?
    public init(state: ModelConnectionState = .notConnected, lastVerified: Date? = nil, expiration: Date? = nil) {
        self.state = state; self.lastVerified = lastVerified; self.expiration = expiration
    }
}

public actor OpenRouterConnection {
    public let credentials: any ModelCredentialStore
    private let settings: (any SettingsStore)?
    private let transport: any OpenRouterTransport
    private var status = ModelConnectionStatus()
    private var busy = false
    private var loadedStatus = false
    private var usedAttempts: [String: Date] = [:]
    public init(credentials: any ModelCredentialStore, settings: (any SettingsStore)? = nil,
                transport: any OpenRouterTransport = BoundedOpenRouterTransport()) {
        self.credentials = credentials; self.settings = settings; self.transport = transport
    }
    public func currentStatus() async -> ModelConnectionStatus {
        if !loadedStatus {
            loadedStatus = true
            if let settings, let text = await settings.currentSnapshot().preferences["openrouter.connection"],
               !busy, text.utf8.count <= 1024, let data = text.data(using: .utf8),
               let saved = try? JSONDecoder().decode(ModelConnectionStatus.self, from: data), saved.state != .connecting { status = saved }
        }
        return status
    }
    public func available() async -> Bool { (try? await credentials.read()) != nil }
    private func persist() async {
        guard let settings, let data = try? JSONEncoder().encode(status), let text = String(data: data, encoding: .utf8) else { return }
        _ = try? await settings.setPreference(key: "openrouter.connection", value: text)
    }
    public func markAuthenticationFailure() async { status.state = .needsAttention; await persist() }
    public func connect(openBrowser: @escaping @Sendable (URL) async -> Bool) async throws {
        guard !busy else { throw ModelFailure.authorization }
        _ = await currentStatus()
        guard !busy else { throw ModelFailure.authorization }
        let old = status; busy = true; status.state = .connecting
        defer { busy = false }
        do {
            let attempt = try PKCEAttempt(); let callback = try LoopbackOAuthCallback()
            guard await openBrowser(attempt.authorizationURL(port: callback.port)) else { throw ModelFailure.authorization }
            let code = try await callback.receive(attempt)
            try Task.checkCancellation()
            try await exchange(code: code, attempt: attempt)
        } catch { status = old; throw error }
    }
    func exchange(code: String, attempt: PKCEAttempt) async throws {
        guard Date() < attempt.expiresAt, !code.isEmpty, code.utf8.count <= 4096 else { throw ModelFailure.authorization }
        usedAttempts = usedAttempts.filter { $0.value > Date() }
        guard usedAttempts[attempt.nonce] == nil, usedAttempts.count < 64 else { throw ModelFailure.authorization }
        usedAttempts[attempt.nonce] = attempt.expiresAt
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": attempt.verifier, "code_challenge_method": "S256"])
        let data = try await transport.send(request, maximumBytes: 16_384)
        guard data.count <= 16_384, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String, !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { throw ModelFailure.malformed }
        let verified = try await verify(key)
        try Task.checkCancellation()
        guard Date() < attempt.expiresAt else { throw ModelFailure.timeout }
        try await credentials.replace(with: key)
        status = verified; await persist()
    }
    private func verify(_ key: String) async throws -> ModelConnectionStatus {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let data = try await transport.send(request, maximumBytes: 16_384)
        guard data.count <= 16_384, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = object["data"] as? [String: Any], metadata["label"] is String else { throw ModelFailure.malformed }
        // Never persist server strings: even a compromised response cannot reflect a key.
        let expiration = (metadata["expires_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return .init(state: .connected, lastVerified: Date(), expiration: expiration)
    }
    public func check() async throws {
        _ = await currentStatus()
        guard !busy else { throw ModelFailure.authorization }; busy = true; defer { busy = false }
        guard let key = try await credentials.read() else { status = .init(); await persist(); throw ModelFailure.disconnected }
        do { status = try await verify(key); await persist() }
        catch { status.state = (error as? ModelFailure) == .authentication ? .needsAttention : .unableToVerify; await persist(); throw error }
    }
    public func disconnect() async throws {
        guard !busy else { throw ModelFailure.authorization }
        busy = true; defer { busy = false }
        try await credentials.remove(); status = .init(); await persist()
    }
}
