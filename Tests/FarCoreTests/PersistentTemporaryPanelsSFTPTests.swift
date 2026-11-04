import Foundation
import Testing
@testable import FarCore

/// Exercises the saved descriptor against real SFTP packets and two SSH jump hosts.
/// Uses the same Paramiko fixture and FAR_TEST_PYTHON setup as the SFTP integration suite.
@Suite struct PersistentTemporaryPanelsSFTPTests {
    @Test func nativeSFTPRestoreUsesOriginalConfigurationAndRejectsChangedEntry() throws {
        let fixture = try JumpSSHFixture()
        defer { fixture.stop() }
        try fixture.trustAll()
        let originalProvider = fixture.provider
        defer { originalProvider.closeConnection() }
        let entry = try #require(try originalProvider.stat(path: "/hello.txt", cancellation: TransferCancellation()))
        let original = SearchMatch.remote(ProviderSearchResult(archiveEntry: nil, remoteEntry: entry, archiveURL: nil,
            connectionID: fixture.connection.id, snippet: "Привет", lineNumber: 1, byteOffset: nil,
            archiveSnapshot: nil, capturedConnection: fixture.connection), originalProvider)
        let reference = try SavedSearchReference(capturing: original)
        originalProvider.closeConnection()
        #expect(fixture.waitUntilDisconnected())
        let authentications = fixture.counter("target", "password")
        var panel = PersistentTemporaryPanels(); try panel.replace([.saved(reference)], in: 3)
        let bytes = try panel.encoded()
        let loaded = try PersistentTemporaryPanels.decode(bytes)
        #expect(loaded.slots[3] == [reference])
        #expect(fixture.counter("target", "password") == authentications)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains(fixture.password) && !text.contains("credential") && !text.contains("known_hosts"))

        let resumed = SFTPProvider(connection: fixture.connection, password: fixture.password, knownHostsURL: fixture.store.url)
        defer { resumed.closeConnection() }
        var requested: [NetworkConnection] = []
        let resolver = SavedSearchResolver(providerFactory: { connection in
            requested.append(connection)
            return resumed
        })
        let restored = try resolver.resolve(try #require(loaded.slots[3].first))
        #expect(requested == [fixture.connection])
        #expect(try SavedSearchReference(capturing: restored) == reference)
        #expect(fixture.counter("target", "password") == authentications + 1)

        var changed = fixture.connection; changed.rootPath = "/different"
        let wrong = SFTPProvider(connection: changed, password: fixture.password, knownHostsURL: fixture.store.url)
        defer { wrong.closeConnection() }
        #expect(throws: NetworkError.changedSource) { try SavedSearchResolver(providerFactory: { _ in wrong }).resolve(reference) }
        #expect(fixture.counter("target", "password") == authentications + 1)

        let cancelled = ProviderSearchCancellation(); cancelled.cancel()
        let factoryCallsBeforeCancel = requested.count
        #expect(throws: (any Error).self) { try resolver.resolve(reference, cancellation: cancelled) }
        #expect(requested.count == factoryCallsBeforeCancel)
        try Data("Replacement differs from captured original".utf8).write(to: fixture.root.appendingPathComponent("files/hello.txt"))
        #expect(throws: NetworkError.changedSource) { try resolver.resolve(reference) }
        #expect(loaded.slots[3] == [reference])
    }
}
