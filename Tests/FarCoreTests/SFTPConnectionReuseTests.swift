import Foundation
import Darwin
import Testing
@testable import FarCore

struct SFTPConnectionReuseTests {
    @Test func fingerprintRejectsFIFODevicesDirectoriesAndOversizedFilesPromptly() throws {
        let root = try snapshotDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let large = root.appendingPathComponent("large")
        try Data(repeating: 0, count: SFTPTrustSnapshot.maximumFileBytes + 1).write(to: large)
        let start = ProcessInfo.processInfo.systemUptime
        for url in [fifo, root, URL(fileURLWithPath: "/dev/null"), large] {
            #expect(throws: SFTPError.invalidConfiguration) { _ = try snapshot(url) }
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }

    @Test func fingerprintDetectsSameSizePinAndIdentityChangesAndSupportsSelectedIdentitySymlink() throws {
        let root = try snapshotDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let pins = root.appendingPathComponent("pins"), key = root.appendingPathComponent("key"), link = root.appendingPathComponent("link")
        try Data("pins-one".utf8).write(to: pins)
        try Data("key-one".utf8).write(to: key)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
        let first = try snapshot(pins, identities: [link.path])
        #expect(try snapshot(pins, identities: [link.path]) == first)
        try Data("pins-two".utf8).write(to: pins)
        let second = try snapshot(pins, identities: [link.path])
        #expect(first != second)
        try Data("key-two".utf8).write(to: key)
        #expect(try snapshot(pins, identities: [link.path]) != second)
        // The app's pins are app-owned; a final-component symlink is rejected.
        #expect(throws: SFTPError.invalidConfiguration) { _ = try snapshot(link) }
    }

    @Test func fingerprintChecksRequestAndConnectionCancellationAndMissingFileTransition() throws {
        let root = try snapshotDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("missing")
        let absent = try snapshot(url)
        try Data().write(to: url)
        #expect(try snapshot(url) != absent)
        let request = TransferCancellation(); request.cancel()
        #expect(throws: SFTPError.cancelled) {
            _ = try SFTPTrustSnapshot.capture(knownHostsURL: url, identities: [], cancellation: request,
                                              connectionCancellation: TransferCancellation(), timeout: 1)
        }
        let lifetime = TransferCancellation(); lifetime.cancel()
        #expect(throws: SFTPError.cancelled) {
            _ = try SFTPTrustSnapshot.capture(knownHostsURL: url, identities: [], cancellation: TransferCancellation(),
                                              connectionCancellation: lifetime, timeout: 1)
        }
    }
}
private func snapshotDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("farmac-trust-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}
private func snapshot(_ url: URL, identities: [String] = []) throws -> Data {
    try SFTPTrustSnapshot.capture(knownHostsURL: url, identities: identities, cancellation: TransferCancellation(),
                                 connectionCancellation: TransferCancellation(), timeout: 1)
}
