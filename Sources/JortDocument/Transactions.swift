import Foundation

public enum DocumentError: Error, Equatable, Sendable {
    case invalidState, staleRevision(expected: Int64, actual: Int64), missingAnchor, invalidRange
}
public struct Landmark: Codable, Equatable, Sendable {
    public let id: UUID
    public let lineID: UUID
    public let emoji: String
    public init(id: UUID = UUID(), lineID: UUID, emoji: String) { self.id = id; self.lineID = lineID; self.emoji = emoji }
}
public struct DocumentSnapshot: Equatable, Sendable {
    public let documentID: UUID
    public let text: String
    public let revision: Int64
    public let lines: [LineMeta]
    public let landmarks: [Landmark]
    public init(documentID: UUID = UUID(), text: String = "", revision: Int64 = 0, lines: [LineMeta] = [LineMeta(location: 0, length: 0)], landmarks: [Landmark] = []) {
        self.documentID = documentID; self.text = text; self.revision = revision; self.lines = lines; self.landmarks = landmarks
    }
    public func validate() throws { try liveState.validate() }
    var liveState: DocumentState { DocumentState(documentID: documentID, landmarks: landmarks, text: text, revision: revision, lines: lines) }
    public func isDetached(_ landmark: Landmark) -> Bool { !lines.contains { $0.id == landmark.lineID } }
}
public enum MutationOrigin: String, Sendable { case native, undo, redo, metadata, restore, automation }
public enum UndoPolicy: Sendable { case register, replay, none }
public enum DocumentMutation: Sendable {
    case edit(text: String, range: NSRange?, replacementLength: Int?)
    case restore(DocumentSnapshot)
    case landmark(Landmark)
    case removeLandmark(UUID)
    case insertAfter(lineID: UUID, text: String)
}
public struct DocumentTransaction: Sendable {
    public let baseRevision: Int64
    public let origin: MutationOrigin
    public let undoPolicy: UndoPolicy
    public let mutation: DocumentMutation
    public init(baseRevision: Int64, origin: MutationOrigin, undoPolicy: UndoPolicy = .register, mutation: DocumentMutation) {
        self.baseRevision = baseRevision; self.origin = origin; self.undoPolicy = undoPolicy; self.mutation = mutation
    }
}
public struct TransactionResult: Sendable {
    public let before: DocumentSnapshot
    public let after: DocumentSnapshot
    public let transaction: DocumentTransaction
    public let removedLineIDs: Set<UUID>
    public let insertedLineIDs: Set<UUID>
}

/// The only mutable live document. Storage and adapters receive value snapshots.
@MainActor public final class DocumentCoordinator {
    private var state: DocumentState
    public private(set) var committedRevision: Int64?
    public var onTransaction: (@MainActor (TransactionResult) -> Void)?
    public var snapshot: DocumentSnapshot {
        DocumentSnapshot(documentID: state.documentID, text: state.text, revision: state.revision, lines: state.lines, landmarks: state.landmarks)
    }
    public init(snapshot: DocumentSnapshot = DocumentSnapshot(), committed: Bool = false) throws {
        try snapshot.validate(); state = snapshot.liveState
        committedRevision = committed ? snapshot.revision : nil
    }
    public func markCommitted(_ revision: Int64) {
        guard revision >= 0, revision <= state.revision else { return }
        committedRevision = max(committedRevision ?? -1, revision)
    }
    @discardableResult public func apply(_ transaction: DocumentTransaction, at time: Date = Date()) throws -> TransactionResult {
        guard transaction.baseRevision == state.revision else {
            throw DocumentError.staleRevision(expected: transaction.baseRevision, actual: state.revision)
        }
        let before = snapshot
        var next = state
        switch transaction.mutation {
        case .edit(let text, let range, let length):
            if let range, let length {
                let count = state.text.utf16.count
                guard range.location >= 0, range.length >= 0, range.location <= count,
                      range.length <= count - range.location, length >= 0, count - range.length <= Int.max - length,
                      count - range.length + length == text.utf16.count else { throw DocumentError.invalidRange }
            }
            next.replaceText(text, editRange: range, replacementLength: length, at: time)
        case .restore(let snapshot):
            try snapshot.validate()
            guard snapshot.documentID == state.documentID else { throw DocumentError.invalidState }
            next = snapshot.liveState
        case .landmark(let landmark):
            guard state.lines.contains(where: { $0.id == landmark.lineID }) else { throw DocumentError.missingAnchor }
            next.landmarks.removeAll { $0.id == landmark.id }; next.landmarks.append(landmark)
        case .removeLandmark(let id): next.landmarks.removeAll { $0.id == id }
        case .insertAfter(let id, let text):
            guard let line = state.lines.first(where: { $0.id == id }) else { throw DocumentError.missingAnchor }
            let offset = line.location + line.length
            let prefix = offset == state.text.utf16.count && !state.text.hasSuffix("\n") ? "\n" : ""
            let inserted = prefix + text + (text.hasSuffix("\n") ? "" : "\n")
            let range = NSRange(location: offset, length: 0)
            next.replaceText((state.text as NSString).replacingCharacters(in: range, with: inserted), editRange: range, replacementLength: inserted.utf16.count, at: time)
        }
        guard state.revision < Int64.max else { throw DocumentError.invalidState }
        next.revision = state.revision + 1
        try next.validate()
        state = next
        let after = snapshot
        let old = Set(before.lines.map(\.id)), new = Set(after.lines.map(\.id))
        let result = TransactionResult(before: before, after: after, transaction: transaction, removedLineIDs: old.subtracting(new), insertedLineIDs: new.subtracting(old))
        onTransaction?(result)
        return result
    }
}
