import Foundation

public struct InvocationPackageReference: Equatable, Sendable {
  public let id: String
  public let version: Int
  public let executor: String
  public let entryContract: Int
  public let inputMode: String
  public let outputOperation: String
  public init(
    id: String, version: Int, executor: String, entryContract: Int,
    inputMode: String, outputOperation: String
  ) {
    self.id = id
    self.version = version
    self.executor = executor
    self.entryContract = entryContract
    self.inputMode = inputMode
    self.outputOperation = outputOperation
  }
  public func accepts(_ manifest: ToolManifest) -> Bool {
    manifest.id == id && manifest.entryContract == entryContract
      && manifest.executorType.rawValue == executor && manifest.inputMode.rawValue == inputMode
      && manifest.outputOperation.rawValue == outputOperation
      && (manifest.version == version || manifest.compatibleVersions?.contains(version) == true)
  }
}
