import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
final class TemporaryPanelLibraryTests {
    private let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FarCommonPanels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    private func file(_ name: String, contents: String = "original") throws -> SearchResult {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return try SearchResult.capture(url)
    }
    private var libraryURL: URL { root.appendingPathComponent("library/panels.json") }

    @Test func tenIndependentSlotsRoundTripAndKeepOriginalStamps() throws {
        let store = TemporaryPanelLibraryStore(url: libraryURL)
        var library = try store.load()
        #expect(library.slots.count == 10 && library.slots.allSatisfy(\.isEmpty))
        #expect(!FileManager.default.fileExists(atPath: libraryURL.path))
        for slot in 0..<10 { try library.replace([file("source\(slot).txt")], in: slot) }
        try library.select(9); try store.save(library)
        let loaded = try TemporaryPanelLibraryStore(url: libraryURL).load()
        #expect(loaded.lastOpenedSlot == 9 && loaded.slots.map(\.count) == Array(repeating: 1, count: 10))
        for slot in 0..<10 {
            #expect(try loaded.items(in: slot).first?.name == "source\(slot).txt")
            try loaded.slots[slot][0].verifyCurrent()
        }
        #expect((try FileManager.default.attributesOfItem(atPath: libraryURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: libraryURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func samePathReplacementCannotBecomeTrustedByAppendReplaceOrRestart() throws {
        let original = try file("source.txt")
        let store = TemporaryPanelLibraryStore(url: libraryURL)
        var library = try store.load(); try library.replace([original], in: 4); try store.save(library)
        try FileManager.default.moveItem(at: original.url, to: root.appendingPathComponent("old-original.txt"))
        let replacement = try file("source.txt", contents: "replacement")
        try library.append([replacement], to: 4); try library.replace([replacement], in: 4)
        try store.save(library)
        let loaded = try TemporaryPanelLibraryStore(url: libraryURL).load()
        #expect(loaded.slots[4].count == 1)
        #expect(throws: (any Error).self) { try loaded.slots[4][0].verifyCurrent() }
        try library.clear(4); try library.append([replacement], to: 4)
        try library.slots[4][0].verifyCurrent()
        #expect(try String(contentsOf: replacement.url, encoding: .utf8) == "replacement")
    }

    @Test func firstSnapshotWinsAndListsKeepAddedOrderWithoutTouchingFiles() throws {
        let first = try file("one.txt"), second = try file("two.txt")
        var library = TemporaryPanelLibrary()
        try library.append([first, second, first], to: 0)
        #expect(library.slots[0].map(\.name) == ["one.txt", "two.txt"])
        try library.replace([second, first], in: 1)
        #expect(library.slots[1].map(\.name) == ["two.txt", "one.txt"])
        try library.clear(0)
        #expect(library.slots[0].isEmpty && library.slots[1].count == 2)
        try first.verifyCurrent(); try second.verifyCurrent()
        #expect(try TemporaryPanelLibrary.decode(library.encoded()).slots[1].map(\.name) == ["two.txt", "one.txt"])
    }

    @Test func changedOrDeletedSourcesArePreservedAsUntrustedOriginalSnapshots() throws {
        let original = try file("changed.txt"), deleted = try file("deleted.txt")
        var library = TemporaryPanelLibrary(); try library.replace([original, deleted], in: 2)
        try Data("longer changed content".utf8).write(to: original.url)
        try FileManager.default.removeItem(at: deleted.url)
        let decoded = try TemporaryPanelLibrary.decode(library.encoded())
        #expect(decoded.slots[2].count == 2)
        for item in decoded.slots[2] { #expect(throws: (any Error).self) { try item.verifyCurrent() } }
    }

    @Test func externalLibraryEditsReplacementsAndDeletionsDoNotGetOverwritten() throws {
        let store = TemporaryPanelLibraryStore(url: libraryURL)
        var original = try store.load(); try original.replace([file("original.txt")], in: 0); try store.save(original)
        let other = TemporaryPanelLibraryStore(url: libraryURL)
        var concurrent = try other.load(); try concurrent.replace([file("concurrent.txt")], in: 9); try other.save(concurrent)
        let expected = try Data(contentsOf: libraryURL)
        #expect(throws: (any Error).self) { try store.save(original) }
        #expect(try Data(contentsOf: libraryURL) == expected)
        _ = try store.load()
        let backup = root.appendingPathComponent("saved-library.json")
        try FileManager.default.moveItem(at: libraryURL, to: backup)
        try expected.write(to: libraryURL); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: libraryURL.path)
        #expect(throws: (any Error).self) { try store.save(original) }
        _ = try store.load(); try FileManager.default.removeItem(at: libraryURL)
        #expect(throws: (any Error).self) { try store.save(original) }
        #expect(!FileManager.default.fileExists(atPath: libraryURL.path))
    }

    @Test func malformedOriginalAndUnloadedStoreAreNeverOverwritten() throws {
        let store = TemporaryPanelLibraryStore(url: libraryURL)
        #expect(throws: (any Error).self) { try store.save(TemporaryPanelLibrary()) }
        try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let invalid = Data("{ broken".utf8)
        try invalid.write(to: libraryURL); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: libraryURL.path)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(TemporaryPanelLibrary()) }
        #expect(try Data(contentsOf: libraryURL) == invalid)
    }

    @Test func missingBaselineCannotOverwriteNewlyAppearedLibrary() throws {
        let store = TemporaryPanelLibraryStore(url: libraryURL)
        _ = try store.load()
        let other = TemporaryPanelLibraryStore(url: libraryURL)
        var library = try other.load(); try library.replace([file("appeared.txt")], in: 5); try other.save(library)
        #expect(throws: (any Error).self) { try store.save(TemporaryPanelLibrary()) }
        #expect(try TemporaryPanelLibraryStore(url: libraryURL).load().slots[5].count == 1)
    }

    @Test func specialFilesSymlinksPublicFilesAndNonprivateDirectoriesAreRejected() throws {
        let source = try file("source.txt")
        let store = TemporaryPanelLibraryStore(url: root.appendingPathComponent("special"))
        #expect(mkfifo(store.url.path, 0o600) == 0)
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: (any Error).self) { try store.load() }
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: source.url)
        #expect(throws: (any Error).self) { try store.load() }
        try FileManager.default.removeItem(at: store.url)
        try TemporaryPanelLibrary().encoded().write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)
        #expect(throws: (any Error).self) { try store.load() }
        let publicDirectory = root.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let publicStore = TemporaryPanelLibraryStore(url: publicDirectory.appendingPathComponent("library.json"))
        _ = try publicStore.load()
        #expect(throws: (any Error).self) { try publicStore.save(TemporaryPanelLibrary()) }
    }

    @Test func invalidSlotsVersionsShapesDuplicatesAndLimitsAreRejected() throws {
        var library = TemporaryPanelLibrary()
        for slot in [-1, 10, Int.max] {
            #expect(throws: (any Error).self) { try library.replace([], in: slot) }
            #expect(throws: (any Error).self) { try library.select(slot) }
            #expect(throws: (any Error).self) { try library.items(in: slot) }
        }
        let emptySlots = Array(repeating: [String](), count: 10)
        for object: [String: Any] in [["version": 2, "slots": emptySlots], ["version": true, "slots": emptySlots], ["version": 1, "slots": []], ["version": 1, "slots": emptySlots, "lastOpenedSlot": 10], ["version": 1, "slots": emptySlots, "typo": 1]] {
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try TemporaryPanelLibrary.decode(data) }
        }
        #expect(throws: (any Error).self) { try TemporaryPanelLibrary.decode(Data(repeating: 32, count: TemporaryPanelLibrary.maximumBytes + 1)) }
        #expect(throws: (any Error).self) { try TemporaryPanelLibrary.decode(Data((String(repeating: "[", count: 13) + String(repeating: "]", count: 13)).utf8)) }
        let item = try file("duplicate.txt")
        var object = try JSONSerialization.jsonObject(with: TemporaryPanelLibrary().encoded()) as! [String: Any]
        let entry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
        var slots = Array(repeating: [Any](), count: 10); slots[0] = [entry, entry]; object["slots"] = slots
        #expect(throws: (any Error).self) { try TemporaryPanelLibrary.decode(JSONSerialization.data(withJSONObject: object)) }
    }
}
