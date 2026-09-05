import XCTest
import Foundation
import Darwin
import JortPersistence

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
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Store/Recovery.json"))) as? [String: Any])
        XCTAssertEqual((json["document"] as? [String: Any])?["content"] as? String, "process save")
        kill(reopened.processIdentifier, SIGKILL); reopened.waitUntilExit()
    }
    func testDifferentStoresHaveIndependentProcessOwners() throws {
        let base = FileManager.default.temporaryDirectory
        let (a, _) = try launch(base.appendingPathComponent("OwnerA-\(UUID())"), mode: "lock")
        let (b, _) = try launch(base.appendingPathComponent("OwnerB-\(UUID())"), mode: "lock")
        a.waitUntilExit(); b.waitUntilExit()
        XCTAssertEqual(a.terminationStatus, 0); XCTAssertEqual(b.terminationStatus, 0)
    }
}
