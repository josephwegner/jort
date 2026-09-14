import Foundation
import XCTest
import JortPersistence
import JortSettings

/// Retains resources independently of a test's success path. XCTest records each
/// cleanup failure as a secondary issue rather than replacing a thrown test error.
final class TestStoreResources: @unchecked Sendable {
  private let report: @Sendable (String) -> Void
  init(report: @escaping @Sendable (String) -> Void = { XCTFail($0) }) {
    self.report = report
  }
  private let lock = NSLock()
  private var closers: [@Sendable () async throws -> Void] = []
  private var preparations: [@Sendable () async -> Void] = []
  private var directories: Set<URL> = []

  func retain(close: @escaping @Sendable () async throws -> Void) {
    lock.withLock { closers.append(close) }
  }

  func prepare(_ action: @escaping @Sendable () async -> Void) {
    lock.withLock { preparations.append(action) }
  }

  func removeAfterClose(_ directory: URL) {
    _ = lock.withLock { directories.insert(directory) }
  }

  func cleanup() async {
    let (preparations, closers, directories) = lock.withLock {
      let value = (self.preparations, self.closers, self.directories)
      self.preparations = []
      self.closers = []
      self.directories = []
      return value
    }
    for prepare in preparations.reversed() { await prepare() }
    var closed = true
    for close in closers.reversed() {
      do { try await close() } catch {
        closed = false
        report("Secondary store cleanup failure: \(error)")
      }
    }
    // A failed close must never turn into unlinking a potentially live database.
    guard closed else { return }
    for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
      guard FileManager.default.fileExists(atPath: directory.path) else { continue }
      do { try FileManager.default.removeItem(at: directory) } catch {
        report("Secondary directory cleanup failure at \(directory.path): \(error)")
      }
    }
  }
}

class StoreTestCase: XCTestCase {
  let storeResources = TestStoreResources()

  override func setUp() {
    super.setUp()
    addTeardownBlock { [storeResources] in await storeResources.cleanup() }
  }

  func ownStore(_ store: SQLiteStore) -> SQLiteStore {
    storeResources.retain { try await store.close() }
    return store
  }

  func ownStore<T: SettingsStore>(_ store: T) -> T {
    storeResources.retain { try await store.close() }
    return store
  }

  func removeAfterStoresClose(_ directory: URL) {
    storeResources.removeAfterClose(directory)
  }

  @MainActor func ownPersistence(directory: URL) -> PersistenceController {
    removeAfterStoresClose(directory)
    return ownPersistence(store: ownStore(SQLiteStore(directory: directory)))
  }

  @MainActor func ownPersistence(store: SQLiteStore) -> PersistenceController {
    let controller = PersistenceController(store: store)
    storeResources.prepare { @MainActor in
      // Drain pending persistence/history work before the retained store closes.
      // A failed save is already observable by the test and may be intentional.
      await withCheckedContinuation { continuation in
        controller.flushLifecycle(reason: .shutdown) { _ in continuation.resume() }
      }
    }
    return controller
  }
}
