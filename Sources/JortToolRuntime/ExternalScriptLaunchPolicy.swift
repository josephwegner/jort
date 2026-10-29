import Foundation

/// A validated direct-process launch description. The caller must launch these
/// fields as an argument vector; this policy never builds a shell command.
public struct ExternalScriptLaunchPlan: Sendable, Equatable {
  public let executablePath: String
  public let arguments: [String]
  public let workingDirectoryPath: String
  public let environment: [String: String]

  public init(
    executablePath: String, arguments: [String], workingDirectoryPath: String,
    environment: [String: String]
  ) {
    self.executablePath = executablePath
    self.arguments = arguments
    self.workingDirectoryPath = workingDirectoryPath
    self.environment = environment
  }
}

/// Fixed launch-policy failures. Cases intentionally carry no filesystem or
/// child-process details so callers can safely expose their fixed messages.
public enum ExternalScriptLaunchPolicyError: Error, Sendable, Equatable, LocalizedError {
  case invalidPath
  case missingScript
  case unsupportedScript
  case invalidInterpreterOverride
  case missingRuntime

  public var errorDescription: String? {
    switch self {
    case .invalidPath:
      "The script path must be an absolute path or begin with ~/."
    case .missingScript:
      "The script is unavailable."
    case .unsupportedScript:
      "The script must be a regular executable file."
    case .invalidInterpreterOverride:
      "The Python interpreter must be an absolute path."
    case .missingRuntime:
      "Install Python or select an absolute Python interpreter."
    }
  }
}

/// Produces deterministic, host-side launch plans for trusted external scripts.
/// It deliberately performs no process launch, shell parsing, or PATH discovery.
public struct ExternalScriptLaunchPolicy: Sendable {
  public static let defaultSearchPaths = [
    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
  ]
  public static let scriptPathByteLimit = 4_096

  private let environment: [String: String]
  private let homeDirectoryPath: String
  private let temporaryDirectoryPath: String
  private let userName: String
  private let searchPaths: [String]

  /// Dependencies are injectable to make policy tests independent of the host
  /// machine. The defaults are the documented production launch context.
  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectoryPath: String = NSHomeDirectory(),
    temporaryDirectoryPath: String = NSTemporaryDirectory(),
    userName: String = NSUserName(),
    searchPaths: [String] = ExternalScriptLaunchPolicy.defaultSearchPaths
  ) {
    self.environment = environment
    self.homeDirectoryPath = homeDirectoryPath
    self.temporaryDirectoryPath = temporaryDirectoryPath
    self.userName = userName
    self.searchPaths = searchPaths
  }

  public func makePlan(scriptPath: String, pythonInterpreterOverride: String? = nil) throws
    -> ExternalScriptLaunchPlan
  {
    let resolvedScriptPath = try resolveScriptPath(scriptPath)
    let scriptURL = URL(fileURLWithPath: resolvedScriptPath)
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(
        atPath: scriptURL.resolvingSymlinksInPath().path)
    } catch {
      throw ExternalScriptLaunchPolicyError.missingScript
    }
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw ExternalScriptLaunchPolicyError.unsupportedScript
    }

    let isPython = resolvedScriptPath.lowercased().hasSuffix(".py")
    let executablePath: String
    let arguments: [String]
    if isPython {
      executablePath = try resolvePython(override: pythonInterpreterOverride)
      arguments = [resolvedScriptPath]
    } else {
      guard FileManager.default.isExecutableFile(atPath: resolvedScriptPath) else {
        throw ExternalScriptLaunchPolicyError.unsupportedScript
      }
      executablePath = resolvedScriptPath
      arguments = []
    }

    return .init(
      executablePath: executablePath,
      arguments: arguments,
      workingDirectoryPath: scriptURL.deletingLastPathComponent().path,
      environment: launchEnvironment())
  }

  private func resolveScriptPath(_ path: String) throws -> String {
    guard path.utf8.count <= Self.scriptPathByteLimit, !path.contains("\0"), !isURL(path) else {
      throw ExternalScriptLaunchPolicyError.invalidPath
    }
    if path.hasPrefix("~/") {
      return URL(fileURLWithPath: homeDirectoryPath).appendingPathComponent(
        String(path.dropFirst(2))
      ).path
    }
    guard path.hasPrefix("/") else { throw ExternalScriptLaunchPolicyError.invalidPath }
    return path
  }

  private func resolvePython(override: String?) throws -> String {
    if let override, !override.isEmpty {
      guard isAbsoluteFilesystemPath(override) else {
        throw ExternalScriptLaunchPolicyError.invalidInterpreterOverride
      }
      guard isUsableExecutable(override) else {
        throw ExternalScriptLaunchPolicyError.missingRuntime
      }
      return override
    }
    for directory in searchPaths {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent("python3").path
      if isUsableExecutable(candidate) { return candidate }
    }
    throw ExternalScriptLaunchPolicyError.missingRuntime
  }

  private func isAbsoluteFilesystemPath(_ path: String) -> Bool {
    !path.contains("\0") && path.hasPrefix("/") && !isURL(path)
  }

  private func isUsableExecutable(_ path: String) -> Bool {
    guard
      let attributes = try? FileManager.default.attributesOfItem(
        atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
      attributes[.type] as? FileAttributeType == .typeRegular
    else { return false }
    return FileManager.default.isExecutableFile(atPath: path)
  }

  private func launchEnvironment() -> [String: String] {
    var result = [
      "PATH": searchPaths.joined(separator: ":"),
      "HOME": homeDirectoryPath,
      "TMPDIR": temporaryDirectoryPath,
      "USER": userName,
      "LOGNAME": userName,
    ]
    for key in ["LANG", "LC_ALL", "LC_CTYPE"] {
      if let locale = environment[key], isValidLocale(locale) { result[key] = locale }
    }
    if result["LANG"] == nil { result["LANG"] = "en_US.UTF-8" }
    return result
  }

  private func isURL(_ value: String) -> Bool {
    URL(string: value)?.scheme != nil
  }

  private func isValidLocale(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128, !value.contains("\0") else { return false }
    return value.unicodeScalars.allSatisfy {
      ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90)
        || ($0.value >= 97 && $0.value <= 122) || "._@+-".unicodeScalars.contains($0)
    }
  }
}
