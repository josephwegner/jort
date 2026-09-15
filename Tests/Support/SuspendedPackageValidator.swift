import Foundation
import JortToolContracts

actor SuspendedPackageValidator: ToolPackageValidator {
  private var pending: [CheckedContinuation<Void, Never>] = []
  private var observers: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private(set) var calls = 0
  func validatePackage(_ package: ToolPackage) async throws {
    try package.validate()
    calls += 1
    observers.forEach { $0.resume() }
    observers = []
    if !released { await withCheckedContinuation { pending.append($0) } }
  }
  func waitUntilRequested() async {
    if calls == 0 { await withCheckedContinuation { observers.append($0) } }
  }
  func release() {
    released = true
    pending.forEach { $0.resume() }
    pending = []
  }
}
