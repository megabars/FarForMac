import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite(.serialized)
struct SFTPProviderTests {
    @Test func binaryPacketDecoderRejectsTruncationAndOversizedStrings() throws {
        var short = SFTPPacket(type: 105, data: Data([0, 0, 0]))
        #expect(throws: SFTPError.malformedPacket) { _ = try short.uint32() }
        var huge = SFTPPacket(type: 103, data: SFTPPacket.uint32(UInt32.max))
        #expect(throws: SFTPError.malformedPacket) { _ = try huge.bytes() }
        var unsupported = SFTPPacket(type: 105, data: SFTPPacket.uint32(16))
        #expect(throws: SFTPError.malformedPacket) { _ = try unsupported.attributes() }
        var invalidText = SFTPPacket(type: 104, data: SFTPPacket.string(Data([0xff])))
        #expect(throws: SFTPError.malformedPacket) { _ = try invalidText.text() }
    }

    @Test func secureSSHArgumentsNeverEnableShellOrImplicitTrust() throws {
        let c = NetworkConnection(kind: .sftp, host: "example.test", username: "user", privateKeyPath: "/tmp/key with space")
        let args = try SFTPProvider.sshArguments(connection: c, knownHostsURL: URL(fileURLWithPath: "/tmp/app trust/known_hosts"))
        #expect(args.contains("StrictHostKeyChecking=yes"))
        #expect(args.contains("GlobalKnownHostsFile=/dev/null"))
        #expect(args.contains("UpdateHostKeys=no"))
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("PasswordAuthentication=no"))
        #expect(args.contains("/tmp/key with space"))
        #expect(Array(args.suffix(3)) == ["--", "example.test", "sftp"])
        #expect(args.contains("-s"))
        var invalid = c; invalid.host = "-oProxyCommand=touch /tmp/unwanted"
        #expect(throws: SFTPError.invalidConfiguration) { _ = try SFTPProvider.sshArguments(connection: invalid, knownHostsURL: URL(fileURLWithPath: "/tmp/known_hosts")) }
    }

    @Test func realSSHRejectsUnknownAndChangedKeysBeforeExchangingFiles() throws {
        let fixture = try SFTPFixture(); defer { fixture.stop() }
        let token = TransferCancellation()
        #expect(throws: SFTPError.unknownHostKey) { _ = try fixture.provider.list(path: fixture.directory.path, cancellation: token) }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
        let keys = try fixture.store.probe(connection: fixture.connection, cancellation: token)
        #expect(!keys.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url.path))
        for key in keys { try fixture.store.trust(key) }
        #expect(try fixture.provider.stat(path: fixture.directory.path, cancellation: token)?.isDirectory == true)
        let other = fixture.directory.appendingPathComponent("other-host")
        try fixture.generateKey(other)
        let publicParts = try String(contentsOf: other.appendingPathExtension("pub"), encoding: .utf8).split(separator: " ")
        try fixture.store.trust(SFTPHostKey(host: "127.0.0.1", port: fixture.connection.port,
            keyType: String(publicParts[0]), publicKey: String(publicParts[1])))
        #expect(throws: SFTPError.changedHostKey) { _ = try fixture.provider.list(path: fixture.directory.path, cancellation: token) }
    }

    @Test func realSSHSupportsOpaqueNamesProgressResumeCRUDAndCleanupOnCancellation() throws {
        let f = try SFTPFixture(); defer { f.stop() }; try f.trustHost()
        let p = f.provider; let token = TransferCancellation()
        let remoteDir = f.directory.appendingPathComponent("remote ' Юникод ; $()")
        try p.makeDirectory(path: remoteDir.path, cancellation: token)
        let path = remoteDir.appendingPathComponent("file ' ; $(no-shell) Привет.txt").path
        let bytes = Data((0..<130_019).map { UInt8($0 % 251) })
        let local = f.directory.appendingPathComponent("local")
        try bytes.write(to: local)
        var uploadProgress: [Int64] = []
        try p.upload(from: local, to: path, cancellation: token) { uploadProgress.append($0.completedBytes) }
        #expect(uploadProgress.first == 0); #expect(uploadProgress.last == Int64(bytes.count))
        let entry = try #require(try p.stat(path: path, cancellation: token))
        #expect(entry.size == bytes.count); #expect(!entry.isDirectory)
        let listing = try p.list(path: remoteDir.path, cancellation: token)
        #expect(listing.map(\.path) == [path])
        let downloaded = f.directory.appendingPathComponent("download")
        var progress: [Int64] = []
        try p.download(path: path, to: downloaded, resumeOffset: 0, cancellation: token) { progress.append($0.completedBytes) }
        #expect(try Data(contentsOf: downloaded) == bytes)
        #expect(progress.last == Int64(bytes.count))
        try bytes.prefix(31_337).write(to: downloaded)
        try p.download(path: path, to: downloaded, resumeOffset: 31_337, cancellation: token) { _ in }
        #expect(try Data(contentsOf: downloaded) == bytes)
        let renamed = remoteDir.appendingPathComponent("renamed").path
        try p.rename(from: path, to: renamed, replace: false, cancellation: token)
        #expect(try p.stat(path: path, cancellation: token) == nil)
        // Replacement is published by posix-rename, preserving a complete old file until commit.
        try p.upload(from: local, to: renamed, cancellation: token) { _ in }
        let existing = remoteDir.appendingPathComponent("existing")
        try Data("old".utf8).write(to: existing)
        #expect(throws: (any Error).self) { try p.rename(from: renamed, to: existing.path, replace: false, cancellation: token) }
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
        let cancelled = TransferCancellation()
        #expect(throws: SFTPError.cancelled) {
            try p.upload(from: local, to: renamed, cancellation: cancelled) { if $0.completedBytes > 0 { cancelled.cancel() } }
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: renamed)) == bytes)
        #expect(try p.list(path: remoteDir.path, cancellation: token).allSatisfy { !$0.name.hasPrefix(".farmac-upload-") })
        let link = remoteDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: local)
        #expect(try p.stat(path: link.path, cancellation: token)?.isSymbolicLink == true)
        #expect(throws: (any Error).self) { try p.download(path: link.path, to: downloaded, resumeOffset: 0, cancellation: token) { _ in } }
        try p.remove(path: link.path, isDirectory: false, cancellation: token)
        try p.remove(path: existing.path, isDirectory: false, cancellation: token)
        try p.remove(path: renamed, isDirectory: false, cancellation: token)
        try Data().write(to: local)
        try p.upload(from: local, to: path, cancellation: token) { _ in }
        try p.download(path: path, to: downloaded, resumeOffset: 0, cancellation: token) { _ in }
        #expect(try Data(contentsOf: downloaded).isEmpty)
        try p.remove(path: path, isDirectory: false, cancellation: token)
        try p.remove(path: remoteDir.path, isDirectory: true, cancellation: token)
        #expect(try p.stat(path: remoteDir.path, cancellation: token) == nil)
    }

    @Test func timeoutAndPreCancelledTokenStopSubsystemPromptly() throws {
        let c = NetworkConnection(kind: .sftp, host: "127.0.0.1", username: NSUserName(), timeoutSeconds: 0.15)
        let hung = SFTPProvider(connection: c, subsystemExecutable: "/bin/sleep", arguments: ["20"])
        let start = Date()
        #expect(throws: SFTPError.timedOut) { _ = try hung.list(path: "/", cancellation: TransferCancellation()) }
        #expect(Date().timeIntervalSince(start) < 2)
        let cancelled = TransferCancellation(); cancelled.cancel()
        #expect(throws: SFTPError.cancelled) { _ = try hung.list(path: "/", cancellation: cancelled) }
    }
}

/// A private unprivileged SSH daemon on loopback, with ephemeral server/client keys.
/// Does not change Remote Login, system sshd configuration, the user's SSH files or agent.
private final class SFTPFixture {
    let directory: URL
    let connection: NetworkConnection
    let store: SFTPHostKeyStore
    let server = Process()
    let log: FileHandle
    var provider: SFTPProvider { SFTPProvider(connection: connection, knownHostsURL: store.url) }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("farmac-sftp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EIO) }; var ownsSocket = true
        defer { if ownsSocket { close(socketFD) } }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) } }
        let port = Int(UInt16(bigEndian: address.sin_port))
        connection = NetworkConnection(kind: .sftp, host: "127.0.0.1", port: port, username: NSUserName(),
            privateKeyPath: directory.appendingPathComponent("client").path, timeoutSeconds: 3)
        store = SFTPHostKeyStore(url: directory.appendingPathComponent("known_hosts"))
        let logURL = directory.appendingPathComponent("sshd.log")
        _ = FileManager.default.createFile(atPath: logURL.path, contents: Data())
        log = try FileHandle(forWritingTo: logURL)
        try generateKey(directory.appendingPathComponent("host"))
        try generateKey(directory.appendingPathComponent("client"))
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey "\(directory.path)/host"
        PidFile "\(directory.path)/sshd.pid"
        AuthorizedKeysFile "\(directory.path)/client.pub"
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        Subsystem sftp /usr/libexec/sftp-server
        LogLevel ERROR
        """
        let configURL = directory.appendingPathComponent("sshd_config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        // Release the port only immediately before starting the daemon.
        close(socketFD); ownsSocket = false
        server.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        server.arguments = ["-D", "-e", "-f", configURL.path]
        server.standardOutput = log; server.standardError = log
        try server.run()
        Thread.sleep(forTimeInterval: 0.12)
        guard server.isRunning else { throw SFTPError.transport((try? String(contentsOf: logURL, encoding: .utf8)) ?? "Тестовый sshd не запустился.") }
    }
    func generateKey(_ url: URL) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", url.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw SFTPError.transport("ssh-keygen fixture failed") }
    }
    func trustHost() throws { for key in try store.probe(connection: connection, cancellation: TransferCancellation()) { try store.trust(key) } }
    func stop() {
        if server.isRunning { server.terminate(); server.waitUntilExit() }
        try? log.close(); try? FileManager.default.removeItem(at: directory)
    }
    deinit { stop() }
}
