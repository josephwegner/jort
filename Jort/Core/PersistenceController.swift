import AppKit

final class PersistenceController {
    private let queue = DispatchQueue(label: "dev.jort.persistence", qos: .utility)
    private let store: DocumentStore
    private let retryDelays: [TimeInterval]
    private var timer: Timer?
    private var retryCount = 0
    private var writing = false
    private(set) var loadedSafely = false
    private var savedRevision: Int64 = -1
    var state = DocumentState()
    var onStatus: ((String, Bool) -> Void)?

    init(directory: URL) {
        store = SQLiteStore(directory: directory)
        retryDelays = [1, 2, 3]
    }
    init(store: DocumentStore, retryDelays: [TimeInterval]) {
        self.store = store
        self.retryDelays = retryDelays
    }

    func load(completion: @escaping (DocumentState) -> Void) {
        queue.async {
            let result: Result<(DocumentState, Bool), Error>
            do { result = .success((try self.store.load() ?? DocumentState(), false)) }
            catch {
                if (error as? StoreError)?.isCorruption == true || error is DecodingError {
                    do { result = .success((try self.store.recover(), true)) }
                    catch { result = .failure(error) }
                } else { result = .failure(error) }
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let (state, recovered)):
                    self.state = state
                    self.savedRevision = state.revision
                    self.loadedSafely = true
                    self.onStatus?(recovered ? "Recovered your last safe save. Damaged storage was preserved." : "Saved on this Mac", recovered)
                case .failure(let error):
                    self.onStatus?("Storage could not be opened: \(error.localizedDescription) Your typing stays in memory; existing files are preserved.", true)
                }
                completion(self.state)
            }
        }
    }

    func changed(_ state: DocumentState) {
        self.state = state
        guard loadedSafely, retryCount <= retryDelays.count else { return }
        onStatus?("Saving…", false)
        // Throttle, rather than trailing debounce: continuous typing still saves every 0.5s.
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.timer = nil
                self?.flush()
            }
        }
    }

    /// A manual retry renews the bounded automatic retry budget.
    func retry() {
        retryCount = 0
        flush()
    }

    /// Explicit emergency backup; never overwrites the damaged canonical store.
    func saveRecoveryCopy(to url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let snapshot = state
        queue.async {
            let result = Result { try JSONEncoder().encode(snapshot).write(to: url, options: .atomic) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func flush(completion: ((Bool) -> Void)? = nil) {
        timer?.invalidate(); timer = nil
        guard loadedSafely else { completion?(false); return }
        guard !writing else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.flush(completion: completion) }
            return
        }
        guard savedRevision != state.revision else { completion?(true); return }
        writing = true
        let snapshot = state
        queue.async {
            let result = Result { try self.store.save(snapshot) }
            DispatchQueue.main.async {
                self.writing = false
                switch result {
                case .success:
                    self.savedRevision = snapshot.revision
                    self.retryCount = 0
                    self.onStatus?(self.state.revision == snapshot.revision ? "Saved on this Mac" : "Saving…", false)
                    if self.state.revision != snapshot.revision { self.flush(completion: completion) }
                    else { completion?(true) }
                case .failure(let error):
                    self.onStatus?("Couldn’t save: \(error.localizedDescription) Your text is still here. Retry saving with ⌘S.", true)
                    self.retryCount += 1
                    if self.retryCount <= self.retryDelays.count {
                        self.timer = Timer.scheduledTimer(withTimeInterval: self.retryDelays[self.retryCount - 1], repeats: false) { [weak self] _ in
                            self?.timer = nil; self?.flush()
                        }
                    }
                    completion?(false)
                }
            }
        }
    }
}
