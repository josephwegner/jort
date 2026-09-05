import Foundation
import JortDocument

public struct SaveFailure: Equatable, Sendable {
    public let error: StoreError
    public let retriesRemaining: Int
}
public enum PersistenceState: Equatable, Sendable {
    case loading, loadBlockedFuture, ownershipConflict
    case clean(committed: Int64), dirty(revision: Int64)
    case writing(revision: Int64, failure: SaveFailure?)
    case retryScheduled(revision: Int64, attempt: Int, failure: SaveFailure)
    case saveFailed(revision: Int64, failure: SaveFailure)
    case loadFailed(StoreError)
    public var failure: SaveFailure? {
        switch self {
        case .writing(_, let failure): return failure
        case .retryScheduled(_, _, let failure), .saveFailed(_, let failure): return failure
        default: return nil
        }
    }
    public var requiresAttention: Bool {
        switch self { case .loadBlockedFuture, .ownershipConflict, .loadFailed: return true; default: return failure != nil }
    }
    public var permitsRetry: Bool {
        switch self { case .clean, .dirty, .writing, .retryScheduled, .saveFailed: return true; default: return false }
    }
}
@MainActor public final class PersistenceController {
    private let store: any DocumentStore
    private let retryDelays: [TimeInterval]
    private var scheduled: Task<Void, Never>?
    private var pending: DocumentSnapshot?
    private var writing = false
    private var failures = 0
    private var ready = false
    private var waiters: [@MainActor (Bool) -> Void] = []
    public private(set) var committedRevision: Int64?
    public private(set) var status: PersistenceState = .loading {
        didSet { onState?(status) }
    }
    public var onState: (@MainActor (PersistenceState) -> Void)?
    public var onCommit: (@MainActor (Int64) -> Void)?
    public init(directory: URL) { store = SQLiteStore(directory: directory); retryDelays = [1, 2, 3] }
    public init(store: any DocumentStore, retryDelays: [TimeInterval] = [1, 2, 3]) { self.store = store; self.retryDelays = retryDelays }
    public func load(completion: @escaping @MainActor (Result<DocumentSnapshot, StoreError>) -> Void) {
        guard !ready else { return }
        status = .loading
        Task {
            do {
                let snapshot: DocumentSnapshot
                do { snapshot = try await store.load() }
                catch let error as StoreError where error.recoverableCorruption { snapshot = try await store.recover() }
                ready = true; pending = snapshot; committedRevision = snapshot.revision
                status = .clean(committed: snapshot.revision)
                completion(.success(snapshot))
            } catch {
                let failure = Self.normalize(error)
                switch failure {
                case .unsupportedVersion: status = .loadBlockedFuture
                case .ownership: status = .ownershipConflict
                default: status = .loadFailed(failure)
                }
                completion(.failure(failure))
            }
        }
    }
    public func changed(_ snapshot: DocumentSnapshot) {
        pending = snapshot
        guard ready else { return }
        if failures > retryDelays.count {
            if let failure = status.failure { status = .saveFailed(revision: snapshot.revision, failure: failure) }
            return
        }
        if status.failure == nil { status = .dirty(revision: snapshot.revision) }
        if scheduled == nil && !writing { schedule(after: 0.5) }
    }
    private func schedule(after delay: TimeInterval) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.scheduled = nil; self.flush()
        }
    }
    public func retry() { failures = 0; flush() }
    public func flush(completion: (@MainActor (Bool) -> Void)? = nil) {
        if let completion { waiters.append(completion) }
        scheduled?.cancel(); scheduled = nil
        guard ready, let snapshot = pending else { finish(false); return }
        guard !writing else { return }
        guard committedRevision != snapshot.revision else { finish(true); return }
        writing = true
        status = .writing(revision: snapshot.revision, failure: status.failure)
        Task {
            do {
                let revision = try await store.save(snapshot)
                guard revision == snapshot.revision else { throw StoreError.io("Committed revision did not match snapshot") }
                writing = false; committedRevision = revision; failures = 0
                onCommit?(revision)
                if pending?.revision != revision { flush() }
                else { status = .clean(committed: revision); finish(true) }
            } catch {
                writing = false; failures += 1
                let remaining = max(0, retryDelays.count - failures + 1)
                let failure = SaveFailure(error: Self.normalize(error), retriesRemaining: remaining)
                let revision = pending?.revision ?? snapshot.revision
                status = .saveFailed(revision: revision, failure: failure)
                if remaining > 0 {
                    status = .retryScheduled(revision: revision, attempt: failures, failure: failure)
                    schedule(after: retryDelays[failures - 1])
                }
                finish(false)
            }
        }
    }
    private func finish(_ success: Bool) {
        let callbacks = waiters; waiters.removeAll()
        for callback in callbacks { callback(success) }
    }
    public func saveRecoveryCopy(snapshot: DocumentSnapshot, to url: URL, completion: @escaping @MainActor (Result<Void, StoreError>) -> Void) {
        Task {
            let result = await Task.detached {
                do { try PersistenceFormat.encode(snapshot).write(to: url, options: .atomic); return Result<Void, StoreError>.success(()) }
                catch { return .failure(Self.normalize(error)) }
            }.value
            completion(result)
        }
    }
    nonisolated private static func normalize(_ error: Error) -> StoreError { (error as? StoreError) ?? .io(String(describing: error)) }
}
