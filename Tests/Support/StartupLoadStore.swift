import Foundation
import JortDocument
import JortPersistence

/// Load completes only when the test explicitly supplies its result.
actor StartupLoadStore: DocumentStore {
  private var continuation: CheckedContinuation<DocumentSnapshot, any Error>?
  private var result: Result<DocumentSnapshot, StoreError>?
  private var holdSaves = false
  private var saveContinuation: CheckedContinuation<Void, Never>?
  private var saveStarted: CheckedContinuation<Void, Never>?
  func delaySaves() { holdSaves = true }
  func waitForSave() async {
    if !writes.isEmpty { return }
    await withCheckedContinuation { saveStarted = $0 }
  }
  func releaseSave() {
    holdSaves = false
    saveContinuation?.resume()
    saveContinuation = nil
  }
  private(set) var writes: [DocumentSnapshot] = []
  func load() async throws -> DocumentSnapshot {
    if let result { return try result.get() }
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }
  func resolve(_ result: Result<DocumentSnapshot, StoreError>) {
    self.result = result
    continuation?.resume(with: result.mapError { $0 as any Error })
    continuation = nil
  }
  func save(_ snapshot: DocumentSnapshot) async -> Int64 {
    writes.append(snapshot)
    saveStarted?.resume()
    saveStarted = nil
    if holdSaves { await withCheckedContinuation { saveContinuation = $0 } }
    return snapshot.revision
  }
  func recover() throws -> DocumentSnapshot { throw StoreError.invalidPayload }
}
