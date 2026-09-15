import Foundation
import XCTest
import JortToolContracts
import JortSettings

private struct RejectingPackageValidator: ToolPackageValidator {
  func validatePackage(_ package: ToolPackage) async throws { throw ToolPackageError.invalidSource }
}

@MainActor final class InjectedValidatorTests: StoreTestCase {
  private func registry(_ validator: any ToolPackageValidator) throws -> ToolPackageRegistry {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    removeAfterStoresClose(root)
    return ToolPackageRegistry(
      validator: validator, bundledDirectory: root.appendingPathComponent("bundled"),
      installedDirectory: root.appendingPathComponent("installed"))
  }
  private var package: ToolPackage {
    .init(
      manifest: .init(id: "dev.test.fake", name: "Fake", command: "/fake"),
      source: "deterministic fake source")
  }
  func testMissingAndRejectingValidatorsCannotPublish() async throws {
    for validator: any ToolPackageValidator in [
      UnavailableToolValidator(), RejectingPackageValidator(),
    ] {
      let registry = try registry(validator)
      let installed = await registry.installedDirectory
      do {
        _ = try await registry.save(package)
        XCTFail("Unexpected publication")
      } catch {}
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: installed.appendingPathComponent("index.json").path))
    }
  }
  func testSaveAwaitsValidatorAndConflictingSaveCannotOverwriteWinner() async throws {
    let validator = SuspendedPackageValidator()
    let registry = try registry(validator)
    let package = package
    let installed = await registry.installedDirectory
    let first = Task { try await registry.save(package, requireAbsent: true) }
    await validator.waitUntilRequested()
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: installed.appendingPathComponent("index.json").path))
    let second = Task { try await registry.save(package, requireAbsent: true) }
    await validator.release()
    let saved = try await first.value
    XCTAssertEqual(saved.executable, [package])
    do {
      _ = try await second.value
      XCTFail("Expected conflict")
    } catch { XCTAssertEqual(error as? ToolPackageError, .conflict) }
    let inspected = try await registry.inspect()
    XCTAssertEqual(inspected.executable, [package])
  }
}
