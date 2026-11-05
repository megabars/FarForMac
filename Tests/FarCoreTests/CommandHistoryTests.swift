import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
struct CommandHistoryTests {
    @Test
    func historyBoundsDeduplicatesFiltersAndRemoves() throws {
        var history = CommandHistory(capacity: 3)
        try history.record(kind: .command, value: "echo Привет", directory: "/tmp")
        let commandID = try #require(history.entries.first?.id)
        try history.record(kind: .view, value: "/tmp/readme.txt")
        try history.record(kind: .edit, value: "/tmp/edit.txt")
        try history.record(kind: .command, value: "echo Привет", directory: "/tmp")
        #expect(history.entries.count == 3)
        #expect(history.entries.first?.id == commandID)
        #expect(history.filtered(kind: .command, query: "ПРИВЕТ").count == 1)
        #expect(history.filtered(query: "readme").count == 1)
        try history.record(kind: .folder, value: "/tmp/folder")
        #expect(history.entries.count == 3)
        #expect(history.filtered(kind: .view).isEmpty)
        history.remove(id: commandID)
        #expect(history.filtered(kind: .command).isEmpty)
        history.clear(kind: .folder)
        #expect(history.entries.count == 1)
        history.clear()
        #expect(history.entries.isEmpty)
    }

    @Test
    func atomicStoreRoundTripsWithoutExecutingAndCanBeCleared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FarHistoryTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        #expect(try CommandHistory.load(from: url).entries.isEmpty)
        var history = CommandHistory(capacity: 5)
        try history.record(kind: .command, value: "$(touch marker); 'Unicode 🦉'", directory: "/tmp")
        try history.record(kind: .view, value: "/tmp/readme")
        try history.save(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let loaded = try CommandHistory.load(from: url)
        #expect(loaded.capacity == 5)
        #expect(loaded.entries == history.entries)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("marker").path))
        #expect(try CommandHistory.load(from: url, capacity: 1).entries.count == 1)
        history.clear()
        try history.save(to: url)
        #expect(try CommandHistory.load(from: url).entries.isEmpty)
    }

    @Test func protectedEntriesSurviveClearingMissingPathsAndCapacityPressure() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var history = CommandHistory(capacity: 2)
        try history.record(kind: .view, value: missing.path)
        let protected = try #require(history.entries.first?.id)
        history.toggleLock(id: protected)
        try history.record(kind: .view, value: missing.path)
        try history.record(kind: .edit, value: missing.appendingPathComponent("file").path)
        try history.record(kind: .command, value: "echo test")
        #expect(history.entries.map(\.id).contains(protected))
        let encoded = try JSONEncoder().encode(history)
        history = try JSONDecoder().decode(CommandHistory.self, from: encoded)
        history.remove(id: protected)
        history.clear(kind: .view)
        history.removeMissing(kinds: [.view, .edit])
        #expect(history.entries.first(where: { $0.id == protected })?.isLocked == true)
        history.toggleLock(id: protected)
        history.removeMissing(kinds: [.view, .edit])
        #expect(history.entries.allSatisfy { $0.kind == .command })
    }

    @Test
    func decodeSanitizesInvalidStateAndBoundsEntries() throws {
        var history = CommandHistory(capacity: 10)
        try history.record(kind: .command, value: "ok", directory: "/tmp")
        let good = try #require(history.entries.first)
        let invalid = ActivityHistoryEntry(kind: .folder, value: "relative")
        let object: [String: Any] = ["capacity": 1, "entries": try [good, good, invalid].map { entry -> Any in
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
        }]
        let decoded = try JSONDecoder().decode(CommandHistory.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.capacity == 1)
        #expect(decoded.entries == [good])
        let empty = try JSONDecoder().decode(CommandHistory.self, from: Data("{}".utf8))
        #expect(empty.entries.isEmpty)
        #expect(CommandHistory(capacity: -1).capacity == 1)
        #expect(CommandHistory(capacity: .max).capacity == 500)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CommandHistory.self, from: Data("{\"entries\":17}".utf8)) }
        #expect(throws: CommandHistoryError.invalidEntry) { try history.record(kind: .command, value: "\0") }
        #expect(throws: CommandHistoryError.invalidEntry) { try history.record(kind: .edit, value: "relative") }
        #expect(throws: CommandHistoryError.invalidEntry) { try history.record(kind: .command, value: " ") }
        #expect(throws: CommandHistoryError.invalidEntry) { try history.record(kind: .command, value: "cd", directory: "relative") }
    }

    @Test
    func corruptAndSymlinkStoresAreRejectedAndRetained() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FarHistoryBad-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        try Data("invalid-json".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try CommandHistory.load(from: url) }
        #expect(try Data(contentsOf: url) == Data("invalid-json".utf8))
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: (any Error).self) { try CommandHistory.load(from: link) }
        #expect(try Data(contentsOf: url) == Data("invalid-json".utf8))
    }
}
