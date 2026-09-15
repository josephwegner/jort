import Foundation
import JortToolContracts

extension ToolPackage {
  public static func load(from directory: URL) throws -> Self {
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw ToolPackageError.invalidPath
    }
    func read(_ name: String, limit: Int) throws -> Data {
      let url = directory.appendingPathComponent(name)
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw ToolPackageError.invalidPath
      }
      guard let size = values.fileSize, size <= limit else { throw ToolPackageError.sizeLimit }
      let data = try Data(contentsOf: url)
      guard data.count <= limit else { throw ToolPackageError.sizeLimit }
      return data
    }
    let manifest = try JSONDecoder().decode(
      ToolManifest.self, from: read("tool.json", limit: 16_384))
    guard
      let source = String(
        data: try read(
          manifest.executorType == .model ? "instructions.txt" : "tool.js",
          limit: manifest.executorType == .model ? 32_768 : SettingsLimits.maximumSourceBytes),
        encoding: .utf8)
    else {
      throw ToolPackageError.invalidSource
    }
    let package =
      manifest.executorType == .model
      ? Self(manifest: manifest, instructions: source) : Self(manifest: manifest, source: source)
    try package.validate()
    return package
  }
}
