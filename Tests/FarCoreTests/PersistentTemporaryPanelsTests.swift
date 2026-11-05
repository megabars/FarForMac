import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite final class PersistentTemporaryPanelsTests {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FarMixedPanels-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    var storeURL: URL { root.appendingPathComponent("library/mixed-panels.json") }
    func local(_ name: String = "local.txt") throws -> SearchMatch {
        let url = root.appendingPathComponent(name); try Data("original".utf8).write(to: url)
        return .local(try SearchResult.capture(url))
    }
    func archived(_ snapshot: ArchiveSnapshot, _ path: String) throws -> SearchMatch {
        let entry = try #require(snapshot.entries.first { $0.path == path })
        return .archive(ProviderSearchResult(archiveEntry: entry, remoteEntry: nil, archiveURL: snapshot.sourceURL,
            connectionID: nil, snippet: "original", lineNumber: 1, byteOffset: nil, archiveSnapshot: snapshot, capturedConnection: nil))
    }
    private func remote(_ provider: SavedReferenceRemote) throws -> SearchMatch {
        .remote(ProviderSearchResult(archiveEntry: nil, remoteEntry: provider.entry, archiveURL: nil,
            connectionID: provider.connection.id, snippet: "original", lineNumber: 1, byteOffset: nil,
            archiveSnapshot: nil, capturedConnection: provider.connection), provider)
    }
    private func resolver(_ provider: SavedReferenceRemote = SavedReferenceRemote()) -> SavedSearchResolver {
        SavedSearchResolver(providerFactory: { connection in
            guard connection == provider.connection else { throw NetworkError.changedSource }
            return provider
        })
    }
    @Test func threeKindsRoundTripOfflineAndRestoreExactOriginalReferences() throws {
        let fixture = try ArchiveSearchTests()
        let snapshot = try ArchiveReader.open(fixture.archive("outer.zip", [("a.txt", Data("archive".utf8))]))
        let provider = SavedReferenceRemote()
        provider.connection.profileGroup = ["Work", "Storage"]
        let matches = [try local(), try archived(snapshot, "a.txt"), try remote(provider)]
        let references = try matches.map(SavedSearchReference.init(capturing:))
        var library = PersistentTemporaryPanels(); try library.replace(matches + matches, in: 7)
        try library.setLastMixed(matches); try library.select(7)
        let data = try library.encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("password"))
        let loaded = try PersistentTemporaryPanels.decode(data)
        #expect(loaded.slots.count == 10 && loaded.slots[7] == references && loaded.lastMixed == references)
        #expect(loaded.lastOpenedSlot == 7 && provider.calls == 0)
        let worker = resolver(provider)
        for reference in loaded.slots[7] {
            let offline = SearchMatch.saved(reference)
            #expect(offline.id == reference.id && offline.name == reference.name && offline.displayPath == reference.displayPath)
            #expect(throws: (any Error).self) { try offline.verifyCurrent() }
            let live = try worker.resolve(reference)
            #expect(live.id == reference.id)
            #expect(try SavedSearchReference(capturing: live) == reference)
        }
        #expect(provider.calls == 1)
    }
    @Test func missingAndChangedSourcesCanBeSavedWithoutRecaptureButCannotResolve() throws {
        let fixture = try ArchiveSearchTests()
        let outer = try fixture.archive("outer.zip", [("a.txt", Data("old".utf8))])
        let snapshot = try ArchiveReader.open(outer)
        let localMatch = try local(), archiveMatch = try archived(snapshot, "a.txt")
        let references = try [localMatch, archiveMatch].map(SavedSearchReference.init(capturing:))
        if case .local(let value) = localMatch { try FileManager.default.removeItem(at: value.url) }
        try Data("changed outer".utf8).write(to: outer)
        var library = PersistentTemporaryPanels(); try library.replace([localMatch, archiveMatch], in: 0)
        let loaded = try PersistentTemporaryPanels.decode(library.encoded())
        #expect(loaded.slots[0] == references)
        let worker = resolver()
        for reference in loaded.slots[0] { #expect(throws: (any Error).self) { try worker.resolve(reference) } }
    }
    @Test func symlinkParentKeepsOfflineIdentityAfterAliasAndSourceDisappear() throws {
        let directory = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("item"); try Data("bytes".utf8).write(to: source)
        let alias = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let match = SearchMatch.local(try SearchResult.capture(alias.appendingPathComponent("item")))
        let reference = try SavedSearchReference(capturing: match), originalID = match.id
        #expect(reference.id == originalID)
        try FileManager.default.removeItem(at: alias); try FileManager.default.removeItem(at: directory)
        let decoded = try JSONDecoder().decode(SavedSearchReference.self, from: JSONEncoder().encode(reference))
        #expect(match.id == originalID && decoded.id == originalID && decoded == reference)
        #expect(throws: (any Error).self) { try resolver().resolve(decoded) }
    }
    @Test func nestedIdentityNeverPersistsWorkingPathsAndSharedCacheRetainsExactlyOneCopy() throws {
        let fixture = try ArchiveSearchTests()
        let inner = try fixture.archive("inner.zip", [("one.txt", Data("one".utf8)), ("two.txt", Data("two".utf8))])
        let outer = try ArchiveReader.open(fixture.archive("outer.zip", [("nested.zip", try Data(contentsOf: inner))]))
        let frame = try ArchiveNavigationFrame(snapshot: outer).openNested(path: "nested.zip")
        let refs = try [archived(frame.snapshot, "one.txt"), archived(frame.snapshot, "two.txt")].map(SavedSearchReference.init(capturing:))
        let encoded = try JSONEncoder().encode(refs)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("far-archive-"))
        let worker = resolver()
        var first: SearchMatch? = try worker.resolve(refs[0]), second: SearchMatch? = try worker.resolve(refs[1])
        guard case .archive(let a)? = first, case .archive(let b)? = second else { Issue.record("Expected restored archives"); return }
        let workingURL = try #require(a.capturedArchiveSnapshot).sourceURL
        #expect(workingURL == b.capturedArchiveSnapshot?.sourceURL)
        #expect(try SavedSearchReference(capturing: #require(first)) == refs[0])
        worker.cleanup()
        try first?.verifyCurrent(); try second?.verifyCurrent()
        #expect(FileManager.default.fileExists(atPath: workingURL.path))
        // a and b still own the snapshots in this scope; releasing the resolver must
        // never remove a working source while a result owns it.
        first = nil; second = nil
    }
    @Test func resolverCleanupRemovesUnownedNestedWorkspaces() throws {
        let fixture = try ArchiveSearchTests()
        let inner = try fixture.archive("inner.zip", [("one", Data("one".utf8))])
        let outer = try ArchiveReader.open(fixture.archive("outer.zip", [("nested.zip", try Data(contentsOf: inner))]))
        let frame = try ArchiveNavigationFrame(snapshot: outer).openNested(path: "nested.zip")
        let reference = try SavedSearchReference(capturing: archived(frame.snapshot, "one"))
        let worker = resolver()
        func resolvePath() throws -> URL {
            guard case .archive(let result) = try worker.resolve(reference) else { throw ArchiveError.changedArchive }
            return try #require(result.capturedArchiveSnapshot).sourceURL
        }
        let path = try resolvePath(); #expect(FileManager.default.fileExists(atPath: path.path))
        worker.cleanup(); #expect(!FileManager.default.fileExists(atPath: path.path))
    }
    @Test func lazyPasswordsAndExactRemoteProfilePreventSilentReconnect() throws {
        let fixture = try ArchiveSearchTests()
        let inner = try fixture.archive("inner.zip", [("one", Data("one".utf8))])
        let outer = try ArchiveReader.open(fixture.archive("outer.zip", [("nested.zip", try Data(contentsOf: inner))]))
        let frame = try ArchiveNavigationFrame(snapshot: outer).openNested(path: "nested.zip")
        var prompts = 0
        let worker = SavedSearchResolver(providerFactory: { _ in throw NetworkError.unsupported("offline") }, archivePassword: { _, _ in prompts += 1; return nil })
        _ = try worker.resolve(SavedSearchReference(capturing: archived(frame.snapshot, "one")))
        #expect(prompts == 0)
        let provider = SavedReferenceRemote(), reference = try SavedSearchReference(capturing: remote(provider))
        provider.connection.rootPath = "/changed"
        // Saving an existing result preserves its captured profile without consulting
        // a provider which may have been disconnected or reconfigured in the meantime.
        guard case .remote(let originalRemote) = reference else { return }
        let originalMatch = SearchMatch.remote(ProviderSearchResult(archiveEntry: nil, remoteEntry: originalRemote.entry,
            archiveURL: nil, connectionID: originalRemote.connection.id, snippet: originalRemote.snippet,
            lineNumber: originalRemote.lineNumber, byteOffset: originalRemote.byteOffset,
            archiveSnapshot: nil, capturedConnection: originalRemote.connection), provider)
        #expect(try SavedSearchReference(capturing: originalMatch) == reference)
        #expect(throws: NetworkError.changedSource) { try SavedSearchResolver(providerFactory: { _ in provider }).resolve(reference) }
        #expect(provider.calls == 0)
    }
    @Test func cancellationAndPartialFailuresRetainOfflineDescriptors() throws {
        let provider = SavedReferenceRemote()
        let valid = try SavedSearchReference(capturing: remote(provider)), missingMatch = try local()
        if case .local(let value) = missingMatch { try FileManager.default.removeItem(at: value.url) }
        let refs = [try SavedSearchReference(capturing: missingMatch), valid], worker = resolver(provider)
        var result: [SearchMatch] = []
        for reference in refs { result.append((try? worker.resolve(reference)) ?? .saved(reference)) }
        #expect(result.count == 2)
        if case .saved = result[0] {} else { Issue.record("Missing row disappeared") }
        if case .remote = result[1] {} else { Issue.record("Later valid row failed") }
        let token = ProviderSearchCancellation(); token.cancel()
        #expect(throws: (any Error).self) { try worker.resolve(valid, cancellation: token) }
        #expect(provider.calls == 1)
    }
    @Test func slotUpdatesKeepOriginalStampsAndRequireExplicitClear() throws {
        let original = try local(); var library = PersistentTemporaryPanels()
        try library.append([original, original], to: 0); try library.setLastMixed([original])
        let replacement = try local()
        try library.append([replacement], to: 0); try library.replace([replacement], in: 0); try library.setLastMixed([replacement])
        #expect(library.slots[0] == [try SavedSearchReference(capturing: original)])
        #expect(library.lastMixed == [try SavedSearchReference(capturing: replacement)])
        _ = try resolver().resolve(library.lastMixed[0])
        #expect(throws: (any Error).self) { try resolver().resolve(library.slots[0][0]) }
        try library.clear(0); try library.append([replacement], to: 0)
        _ = try resolver().resolve(library.slots[0][0])
    }
    @Test func privateAtomicStoreConflictsAndLegacyMigrationPreserveOriginal() throws {
        let oldURL = storeURL.deletingLastPathComponent().appendingPathComponent("panels.json")
        let legacy = TemporaryPanelLibraryStore(url: oldURL)
        var old = try legacy.load()
        guard case .local(let source) = try local() else { return }
        try old.replace([source], in: 8); try old.select(8); try legacy.save(old)
        let original = try Data(contentsOf: oldURL)
        let store = PersistentTemporaryPanelsStore(url: storeURL)
        var migrated = try store.load()
        #expect(migrated.lastOpenedSlot == 8 && migrated.slots[8].map(\.name) == ["local.txt"])
        #expect(try Data(contentsOf: oldURL) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let other = PersistentTemporaryPanelsStore(url: storeURL)
        var concurrent = try other.load(); try concurrent.select(2); try other.save(concurrent)
        try migrated.select(3)
        #expect(throws: (any Error).self) { try store.save(migrated) }
        #expect(try PersistentTemporaryPanelsStore(url: storeURL).load().lastOpenedSlot == 2)
        #expect(try Data(contentsOf: oldURL) == original)
    }
    @Test func specialFilesLinksAndLoosePermissionsAreRefusedWithoutOverwrite() throws {
        let folder = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(mkfifo(storeURL.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try PersistentTemporaryPanelsStore(url: storeURL).load() }
        try FileManager.default.removeItem(at: storeURL)
        let target = root.appendingPathComponent("target"); try PersistentTemporaryPanels().encoded().write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: storeURL, withDestinationURL: target)
        #expect(throws: (any Error).self) { try PersistentTemporaryPanelsStore(url: storeURL).load() }
        try FileManager.default.removeItem(at: storeURL)
        try PersistentTemporaryPanels().encoded().write(to: storeURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storeURL.path)
        #expect(throws: (any Error).self) { try PersistentTemporaryPanelsStore(url: storeURL).load() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(throws: (any Error).self) { try PersistentTemporaryPanelsStore(url: storeURL).load() }
    }
    @Test func malformedSchemaAndMetadataAreRejectedBeforeOverwrite() throws {
        var library = PersistentTemporaryPanels(); try library.replace([local()], in: 0)
        let baseline = try #require(JSONSerialization.jsonObject(with: library.encoded()) as? [String: Any])
        func reject(_ change: (inout [String: Any]) -> Void) throws {
            var object = baseline; change(&object)
            #expect(throws: (any Error).self) { try PersistentTemporaryPanels.decode(JSONSerialization.data(withJSONObject: object)) }
        }
        try reject { $0["version"] = 2 }; try reject { $0["version"] = true }; try reject { $0["password"] = "never" }
        try reject { $0["lastOpenedSlot"] = 10 }; try reject { $0["slots"] = [] }
        func localMutation(_ object: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
            var slots = object["slots"] as! [[[String: Any]]]
            var wrapper = slots[0][0]["local"] as! [String: Any], result = wrapper["_0"] as! [String: Any]
            change(&result); wrapper["_0"] = result; slots[0][0]["local"] = wrapper; object["slots"] = slots
        }
        try reject { object in localMutation(&object) { $0["url"] = "https://wrong.test/file" } }
        try reject { object in localMutation(&object) { $0["size"] = -1 } }
        try reject { object in localMutation(&object) { $0["capturedIdentityPath"] = "relative/path" } }
        try reject { object in localMutation(&object) { $0["capturedIdentityPath"] = "/parent/../wrong" } }
        try reject { object in localMutation(&object) { $0["lineNumber"] = 0 } }
        try reject { object in localMutation(&object) { $0["snippet"] = String(repeating: "x", count: 65_537) } }
        try reject { object in localMutation(&object) { $0["credentials"] = "forbidden" } }
        try reject { object in
            let slot = (object["slots"] as! [[Any]])[0]
            object["slots"] = [Array(repeating: slot[0], count: 10_001)] + Array(repeating: [], count: 9)
        }
        #expect(throws: (any Error).self) { try PersistentTemporaryPanels.decode(Data(repeating: 32, count: PersistentTemporaryPanels.maximumBytes + 1)) }
        #expect(throws: (any Error).self) { try PersistentTemporaryPanels.decode(Data((String(repeating: "[", count: 30) + String(repeating: "]", count: 30)).utf8)) }
    }
}

private final class SavedReferenceRemote: RemoteProvider {
    var connection = NetworkConnection(name: "Saved", kind: .sftp, host: "saved.test", username: "tester")
    var entry = RemoteEntry(path: "/original.txt", isDirectory: false, size: 8, modified: Date(timeIntervalSince1970: 123), version: "immutable-version")
    var calls = 0
    func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? {
        guard !cancellation.isCancelled else { throw NetworkError.cancelled }; calls += 1; return entry.path == path ? entry : nil
    }
    func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] { throw NetworkError.unsupported("fixture") }
    func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { throw NetworkError.unsupported("fixture") }
    func upload(from: URL, to: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { throw NetworkError.unsupported("fixture") }
    func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("fixture") }
    func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("fixture") }
    func makeDirectory(path: String, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("fixture") }
}
