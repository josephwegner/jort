import XCTest
import Foundation
import Darwin
@testable import JortPersistence

final class ProcessTests: XCTestCase {
    private var executable: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("StoreLockProbe")
    }
    private func launch(_ root: URL, mode: String) throws -> (Process, Pipe) {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = [root.path, mode]
        process.standardOutput = pipe
        try process.run()
        return (process, pipe)
    }
    func testTwoProcessesRaceAndCrashReleasesLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Race-\(UUID())")
        let (a, _) = try launch(root, mode: "lock"), (b, _) = try launch(root, mode: "lock")
        a.waitUntilExit(); b.waitUntilExit()
        XCTAssertEqual([a.terminationStatus, b.terminationStatus].sorted(), [0, 73])
        let (owner, output) = try launch(root, mode: "store")
        XCTAssertTrue(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).contains("OWNED"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Store/Jort.sqlite-wal").path))
        let before = try Data(contentsOf: root.appendingPathComponent("Store/Jort.sqlite"))
        let (duplicate, _) = try launch(root, mode: "store")
        duplicate.waitUntilExit(); XCTAssertEqual(duplicate.terminationStatus, 73)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Store/Jort.sqlite")), before)
        kill(owner.processIdentifier, SIGKILL); owner.waitUntilExit()
        let (afterCrash, _) = try launch(root, mode: "lock")
        afterCrash.waitUntilExit(); XCTAssertEqual(afterCrash.terminationStatus, 0)
        let (reopened, reopenedOutput) = try launch(root, mode: "store")
        XCTAssertTrue(String(decoding: reopenedOutput.fileHandleForReading.availableData, as: UTF8.self).contains("OWNED"))
        let checkpoint = try RecoveryCheckpoints(directory: root.appendingPathComponent("Store"), inject: { _ in }).recover()
        XCTAssertEqual(checkpoint.text, "process save")
        kill(reopened.processIdentifier, SIGKILL); reopened.waitUntilExit()
    }
    func testDifferentStoresHaveIndependentProcessOwners() throws {
        let base = FileManager.default.temporaryDirectory
        let (a, _) = try launch(base.appendingPathComponent("OwnerA-\(UUID())"), mode: "lock")
        let (b, _) = try launch(base.appendingPathComponent("OwnerB-\(UUID())"), mode: "lock")
        a.waitUntilExit(); b.waitUntilExit()
        XCTAssertEqual(a.terminationStatus, 0); XCTAssertEqual(b.terminationStatus, 0)
    }
    func testOneHundredCheckpointWriterCrashes() async throws {
        for iteration in 0..<100 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("WalkCrash-\(UUID())")
            let (writer, pipe) = try launch(root, mode: "crash")
            var acknowledged: Int64 = 0
            for _ in 0..<(1 + (iteration * 37) % 7) {
                var bytes = Data()
                while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                    if byte[0] == 10 { break }; bytes.append(byte)
                }
                acknowledged = try XCTUnwrap(Int64(String(decoding: bytes, as: UTF8.self)))
            }
            kill(writer.processIdentifier, SIGKILL); writer.waitUntilExit()
            let store = SQLiteStore(directory: root)
            let restored = try await store.load()
            XCTAssertGreaterThanOrEqual(restored.revision, acknowledged)
            XCTAssertEqual(restored.landmarks.count, 1)
            try restored.validate()
            try await store.close()
        }
    }
}
