import Foundation

public struct HistoryToolAnnotation: Equatable, Sendable {
    public let command: String
    public let phase: ToolInvocationPhase
    public let containsOutput: Bool
    public var label: String { command + " · " + (phase == .pending ? "Pending merge" : phase == .inputting ? "Input" : phase.rawValue.capitalized) }
}

public struct HistoryChangeLine: Equatable, Sendable {
    public enum Kind: Sendable { case unchanged, added, removed }
    public let kind: Kind
    public let oldOrdinal: Int?
    public let newOrdinal: Int?
    public let text: String
    public let emoji: String?
    public var tools: [HistoryToolAnnotation] = []
}

/// Presentation only. Stable line identities provide anchors, including duplicate text.
public struct HistoryComparison: Sendable {
    public let lines: [HistoryChangeLine]
    public let added: Int
    public let removed: Int
    public let metadataChanged: Bool

    public static func compare(_ old: DocumentSnapshot, _ new: DocumentSnapshot) throws -> HistoryComparison {
        guard old.documentID == new.documentID else { throw DocumentError.invalidState }
        try Task.checkCancellation()
        try old.validate(); try new.validate()
        let oldIndices = Dictionary(uniqueKeysWithValues: old.lines.enumerated().map { ($0.element.id, $0.offset) })
        // Longest increasing subsequence of shared identities: O(n log n), bounded even
        // for completely unrelated snapshots or reordered lines.
        let shared = new.lines.enumerated().compactMap { index, line in oldIndices[line.id].map { (old: $0, new: index) } }
        var tails: [Int] = [], previous = Array(repeating: -1, count: shared.count)
        for i in shared.indices {
            try Task.checkCancellation()
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if shared[tails[mid]].old < shared[i].old { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[i] = tails[low - 1] }
            if low == tails.count { tails.append(i) } else { tails[low] = i }
        }
        var anchors: [(old: Int, new: Int)] = [], index = tails.last ?? -1
        while index >= 0 { anchors.append(shared[index]); index = previous[index] }
        anchors.reverse()
        anchors.append((old.lines.count, new.lines.count))
        let oldText = old.text as NSString, newText = new.text as NSString
        let oldEmoji = Dictionary(uniqueKeysWithValues: old.landmarks.filter { !$0.detached }.map { ($0.lineID, $0.emoji) })
        let newEmoji = Dictionary(uniqueKeysWithValues: new.landmarks.filter { !$0.detached }.map { ($0.lineID, $0.emoji) })
        func toolAnnotations(_ snapshot: DocumentSnapshot) -> [UUID: [HistoryToolAnnotation]] {
            var result: [UUID: [HistoryToolAnnotation]] = [:]
            let indices = Dictionary(uniqueKeysWithValues: snapshot.lines.enumerated().map { ($0.element.id, $0.offset) })
            for invocation in snapshot.invocations {
                guard let scope = invocation.scope.resolve(in: snapshot.lines), let first = indices[invocation.scope.start.lineID] else { continue }
                let output = invocation.output?.resolve(in: snapshot.lines)
                let end = max(NSMaxRange(scope), output.map(NSMaxRange) ?? 0)
                for line in snapshot.lines[first...] {
                    if line.location >= end && line.location != scope.location { break }
                    let containsOutput = output.map { NSIntersectionRange($0, NSRange(location: line.location, length: line.length)).length > 0 || $0.length == 0 && $0.location >= line.location && $0.location < line.location + max(1, line.length) } ?? false
                    result[line.id, default: []].append(.init(command: invocation.command, phase: invocation.phase, containsOutput: containsOutput))
                }
            }
            return result
        }
        let oldTools = toolAnnotations(old), newTools = toolAnnotations(new)
        func content(_ source: NSString, _ line: LineMeta) -> String {
            source.substring(with: NSRange(location: line.location, length: line.length))
        }
        var rows: [HistoryChangeLine] = [], a = 0, b = 0, added = 0, removed = 0
        func remove(_ i: Int) {
            rows.append(.init(kind: .removed, oldOrdinal: i + 1, newOrdinal: nil,
                text: content(oldText, old.lines[i]), emoji: oldEmoji[old.lines[i].id], tools: oldTools[old.lines[i].id] ?? [])); removed += 1
        }
        func add(_ i: Int) {
            rows.append(.init(kind: .added, oldOrdinal: nil, newOrdinal: i + 1,
                text: content(newText, new.lines[i]), emoji: newEmoji[new.lines[i].id], tools: newTools[new.lines[i].id] ?? [])); added += 1
        }
        for anchor in anchors {
            try Task.checkCancellation()
            while a < anchor.old { try Task.checkCancellation(); remove(a); a += 1 }
            while b < anchor.new { try Task.checkCancellation(); add(b); b += 1 }
            guard a < old.lines.count, b < new.lines.count else { break }
            let text = content(newText, new.lines[b])
            if content(oldText, old.lines[a]) == text && oldEmoji[old.lines[a].id] == newEmoji[new.lines[b].id] && oldTools[old.lines[a].id] == newTools[new.lines[b].id] {
                rows.append(.init(kind: .unchanged, oldOrdinal: a + 1, newOrdinal: b + 1, text: text, emoji: newEmoji[new.lines[b].id], tools: newTools[new.lines[b].id] ?? []))
            } else { remove(a); add(b) }
            a += 1; b += 1
        }
        return .init(lines: rows, added: added, removed: removed,
            metadataChanged: old.lines != new.lines || old.landmarks != new.landmarks || old.invocations != new.invocations)
    }
}
