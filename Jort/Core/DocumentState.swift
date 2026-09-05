import Foundation

struct LineMeta: Codable, Equatable {
    var id = UUID()
    var location: Int
    var length: Int
    var createdAt: Date?
    var lastEditedAt: Date?
}

struct DocumentState: Codable, Equatable {
    var schemaVersion = 1
    var text = ""
    var revision: Int64 = 0
    var lines = [LineMeta(location: 0, length: 0)]

    static func ranges(in text: String) -> [NSRange] {
        let source = text as NSString
        var result: [NSRange] = []
        var start = 0
        while start < source.length {
            let range = source.lineRange(for: NSRange(location: start, length: 0))
            result.append(range)
            start = NSMaxRange(range)
        }
        if source.length == 0 || source.character(at: source.length - 1) == 10 || source.character(at: source.length - 1) == 13 {
            result.append(NSRange(location: source.length, length: 0))
        }
        return result
    }

    mutating func replaceText(_ newText: String, editRange: NSRange? = nil, replacementLength: Int? = nil, at time: Date = Date()) {
        guard text != newText else { return }
        let source = newText as NSString
        let oldSource = text as NSString
        let prefix: Int, oldEnd: Int, newEnd: Int
        if let range = editRange, let length = replacementLength,
           range.location >= 0, NSMaxRange(range) <= oldSource.length,
           oldSource.length - range.length + length == source.length {
            prefix = range.location
            oldEnd = NSMaxRange(range)
            newEnd = range.location + length
        } else {
            // Composition and external replacements have no single AppKit edit range.
            let old = Array(text.utf16), new = Array(newText.utf16)
            var head = 0
            while head < min(old.count, new.count), old[head] == new[head] { head += 1 }
            var tail = 0
            while tail < min(old.count, new.count) - head,
                  old[old.count - tail - 1] == new[new.count - tail - 1] { tail += 1 }
            prefix = head; oldEnd = old.count - tail; newEnd = new.count - tail
        }
        let delta = source.length - oldSource.length
        func index(containing offset: Int) -> Int {
            var low = 0, high = lines.count
            while low < high {
                let mid = (low + high) / 2
                if lines[mid].location <= offset { low = mid + 1 } else { high = mid }
            }
            return max(0, low - 1)
        }
        let leading = index(containing: prefix)
        // One neighbor on either side catches CRLF boundary changes and joins.
        let first = max(0, leading - 1)
        let end = min(lines.count, index(containing: oldEnd) + 2)
        let startOffset = lines[first].location
        let oldWindowEnd = end < lines.count ? lines[end].location : oldSource.length
        let newWindowEnd = oldWindowEnd + delta
        let window = source.substring(with: NSRange(location: startOffset, length: newWindowEnd - startOffset))
        var ranges = Self.ranges(in: window)
        if end < lines.count, ranges.last?.length == 0 { ranges.removeLast() }
        var byLocation: [Int: LineMeta] = [:]
        for line in lines[first..<end] { byLocation[line.location] = line }
        var used = Set<UUID>()
        let updated = ranges.map { localRange -> LineMeta in
            let range = NSRange(location: localRange.location + startOffset, length: localRange.length)
            var inherited: LineMeta?
            if range.location < lines[leading].location {
                inherited = byLocation[range.location]
            } else if range.location == lines[leading].location {
                inherited = lines[leading]
            } else if range.location >= newEnd {
                let oldLocation = range.location - delta
                if oldLocation >= oldEnd { inherited = byLocation[oldLocation] }
            }
            if let candidate = inherited, used.contains(candidate.id) { inherited = nil }
            var line = inherited ?? LineMeta(location: range.location, length: range.length)
            used.insert(line.id)
            let content = source.substring(with: range)
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                line.createdAt = nil
                line.lastEditedAt = nil
            } else {
                let unchanged = inherited.map { oldSource.substring(with: NSRange(location: $0.location, length: $0.length)) == content } ?? false
                if line.createdAt == nil { line.createdAt = time }
                if !unchanged { line.lastEditedAt = time }
            }
            line.location = range.location
            line.length = range.length
            return line
        }
        var result = Array(lines[..<first])
        result.append(contentsOf: updated)
        for var line in lines[end...] {
            line.location += delta
            result.append(line)
        }
        text = newText
        lines = result
        revision += 1
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw StoreError.unsupportedVersion }
        let ranges = Self.ranges(in: text)
        guard ranges.count == lines.count,
              Set(lines.map(\.id)).count == lines.count,
              zip(ranges, lines).allSatisfy({ $0.location == $1.location && $0.length == $1.length }) else {
            throw StoreError.message("The saved document metadata is invalid.")
        }
    }
}
