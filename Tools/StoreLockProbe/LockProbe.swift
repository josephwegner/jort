import Foundation
import Darwin
import JortPersistence
import JortDocument

@main enum StoreLockProbe {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else { exit(64) }
        let directory = URL(fileURLWithPath: args[1])
        let mode = args[2]
        do {
            if mode == "lock" {
                let lock = try StoreLock(directory: directory)
                FileHandle.standardOutput.write(Data("OWNED\n".utf8))
                try await Task.sleep(for: .seconds(1))
                withExtendedLifetime(lock) {}
            } else {
                let store = SQLiteStore(directory: directory)
                let snapshot = try await store.load()
                let owner = try DocumentCoordinator(snapshot: snapshot)
                try owner.apply(.init(baseRevision: snapshot.revision, origin: .native, mutation: .edit(text: "process save", range: nil, replacementLength: nil)))
                _ = try await store.save(owner.snapshot)
                FileHandle.standardOutput.write(Data("OWNED\n".utf8))
                // Hold WAL and the advisory lock until the process test forcibly terminates us.
                try await Task.sleep(for: .seconds(60))
                withExtendedLifetime(store) {}
            }
            exit(0)
        } catch StoreError.ownership { exit(73) }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
}
