import XCTest
import Foundation
import JortDocument
import JortPersistence

final class PerformanceTests: XCTestCase {
    @MainActor func testRepresentativeDistributions() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "canvas-10000", withExtension: "txt"))
        let text = try String(contentsOf: fixture, encoding: .utf8)
        let owner = try DocumentCoordinator()
        let pasteStart = ProcessInfo.processInfo.systemUptime
        try owner.apply(.init(baseRevision: 0, origin: .native, mutation: .edit(text: text, range: nil, replacementLength: nil)))
        let paste = ProcessInfo.processInfo.systemUptime - pasteStart
        var edits: [Double] = [], saves: [Double] = []
        for index in 0..<100 {
            let before = owner.snapshot, offset = (index * 7919) % before.text.utf16.count
            let source = before.text as NSString
            // Select a known ASCII line start rather than splitting a Unicode scalar.
            let start = before.lines.last(where: { $0.location <= offset })!.location
            let range = NSRange(location: start, length: 0)
            let changed = source.replacingCharacters(in: range, with: "x")
            let begin = ProcessInfo.processInfo.systemUptime
            try owner.apply(.init(baseRevision: before.revision, origin: .native, mutation: .edit(text: changed, range: range, replacementLength: 1)))
            edits.append(ProcessInfo.processInfo.systemUptime - begin)
            if index % 10 == 0 {
                let snapshot = owner.snapshot
                let elapsed = try await Task.detached {
                    let begin = ProcessInfo.processInfo.systemUptime
                    _ = try PersistenceFormat.encode(snapshot)
                    return ProcessInfo.processInfo.systemUptime - begin
                }.value
                saves.append(elapsed)
            }
        }
        func percentile(_ values: [Double], _ q: Double) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count - 1) * q))] * 1000 }
        print("PERF 10k lines: paste=\(paste * 1000)ms edit p50=\(percentile(edits, 0.5)) p95=\(percentile(edits, 0.95)) p99=\(percentile(edits, 0.99))ms serialization p95=\(percentile(saves, 0.95))ms")
        if ProcessInfo.processInfo.environment["JORT_PERFORMANCE_ENFORCE"] == "1" {
            XCTAssertLessThan(percentile(edits, 0.95), 100)
            XCTAssertLessThan(percentile(saves, 0.95), 250)
            XCTAssertLessThan(paste, 2)
        }
    }
}
