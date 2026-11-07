import Foundation
import Darwin
import Testing
@testable import FarCore

/// Run with FAR_TEST_PYTHON pointing to a Python environment containing
/// Tests/NetworkFixtures/requirements-ssh-password.txt. Uses the real /usr/bin/ssh.
extension SFTPPasswordTests {
    @Test func unicodePasswordExchangesRealSFTPPackets() throws {
        let before = askpassDirectories(); defer { #expect(askpassDirectories().subtracting(before).isEmpty) }
        let f = try PasswordSSHFixture(); defer { f.stop() }
        try f.trust()
        let token = TransferCancellation()
        let data = Data("Содержимое ' ; $(literal) 🐈".utf8)
        let source = f.root.appendingPathComponent("source")
        try data.write(to: source)
        let name = "/Привет ' ; $(literal).txt"
        try f.provider.upload(from: source, to: name, cancellation: token) { _ in }
        #expect(try f.provider.list(path: "/", cancellation: token).contains { $0.name == String(name.dropFirst()) })
        #expect(try f.provider.stat(path: name, cancellation: token)?.size == Int64(data.count))
        let destination = f.root.appendingPathComponent("download")
        try f.provider.download(path: name, to: destination, resumeOffset: 0, cancellation: token) { _ in }
        #expect(try Data(contentsOf: destination) == data)
        #expect(f.authCount >= 4)
    }

    @Test func maximumUTF8PasswordAuthenticatesThroughOpenSSH() throws {
        let before = askpassDirectories(); defer { #expect(askpassDirectories().subtracting(before).isEmpty) }
        let password = String(repeating: "é", count: 511) + "a"
        #expect(password.utf8.count == 1023)
        let f = try PasswordSSHFixture(password: password); defer { f.stop() }; try f.trust()
        #expect(try f.provider.stat(path: "/", cancellation: TransferCancellation())?.isDirectory == true)
        #expect(f.authCount == 1)
    }

    @Test func rejectedPasswordDoesNotLeakSecretInDiagnostics() throws {
        let before = askpassDirectories(); defer { #expect(askpassDirectories().subtracting(before).isEmpty) }
        let f = try PasswordSSHFixture(); defer { f.stop() }; try f.trust()
        let secret = "wrong-秘密-$(literal)"
        let provider = SFTPProvider(connection: f.connection, password: secret, knownHostsURL: f.store.url)
        do {
            _ = try provider.list(path: "/", cancellation: TransferCancellation())
            Issue.record("Incorrect password unexpectedly authenticated")
        } catch {
            #expect(error as? SFTPError == .authenticationFailed)
            #expect(!error.localizedDescription.contains(secret))
            #expect(!error.localizedDescription.contains(f.root.path))
        }
        #expect(f.authCount == 1)
    }

    @Test func hostTrustFailuresNeverSubmitPassword() throws {
        let before = askpassDirectories(); defer { #expect(askpassDirectories().subtracting(before).isEmpty) }
        let f = try PasswordSSHFixture(); defer { f.stop() }
        #expect(throws: SFTPError.unknownHostKey) { _ = try f.provider.list(path: "/", cancellation: TransferCancellation()) }
        #expect(f.authCount == 0)
        let other = try PasswordSSHFixture(); defer { other.stop() }
        try f.store.trust(SFTPHostKey(host: f.connection.host, port: f.connection.port,
                                     keyType: other.keyType, publicKey: other.publicKey))
        #expect(throws: SFTPError.changedHostKey) { _ = try f.provider.list(path: "/", cancellation: TransferCancellation()) }
        #expect(f.authCount == 0)
    }

    @Test func timeoutAndCancellationInterruptPasswordAuthentication() throws {
        let before = askpassDirectories(); defer { #expect(askpassDirectories().subtracting(before).isEmpty) }
        let f = try PasswordSSHFixture(delay: 4); defer { f.stop() }; try f.trust()
        var connection = f.connection; connection.timeoutSeconds = 0.4
        let timed = SFTPProvider(connection: connection, password: f.password, knownHostsURL: f.store.url)
        #expect(throws: SFTPError.timedOut) { _ = try timed.list(path: "/", cancellation: TransferCancellation()) }
        let cancelled = TransferCancellation()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.3)
            cancelled.cancel()
        }
        #expect(throws: SFTPError.cancelled) { _ = try f.provider.list(path: "/", cancellation: cancelled) }
    }
}

final class PasswordSSHFixture {
    let root: URL
    let server = Process()
    let password: String
    let connection: NetworkConnection
    let store: SFTPHostKeyStore
    let keyType: String
    let publicKey: String
    var provider: SFTPProvider { SFTPProvider(connection: connection, password: password, knownHostsURL: store.url) }
    var authCount: Int { Int((try? String(contentsOf: root.appendingPathComponent("auth-count"), encoding: .utf8)) ?? "") ?? 0 }

    init(delay: Double = 0, password: String = "Пароль with ' quotes ; $(literal) 🔐") throws {
        self.password = password
        root = FileManager.default.temporaryDirectory.appendingPathComponent("farmac-password-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("NetworkFixtures/ssh_password_fixture.py")
        let process = server; let rootURL = root
        var ready = false
        defer {
            if !ready {
                stopPasswordFixtureProcess(process)
                try? FileManager.default.removeItem(at: rootURL)
            }
        }
        let input = Pipe(); let output = Pipe()
        let diagnosticURL = root.appendingPathComponent("startup.log")
        _ = FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil)
        let diagnosticHandle = try FileHandle(forWritingTo: diagnosticURL)
        defer { try? diagnosticHandle.close() }
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = [ProcessInfo.processInfo.environment["FAR_TEST_PYTHON"] ?? "python3", fixture.path, root.path, String(delay)]
        server.standardInput = input; server.standardOutput = output
        server.standardError = diagnosticHandle
        try server.run()
        try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
        try input.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw POSIXError(.EIO) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        var line = Data()
        var complete = false
        while DispatchTime.now().uptimeNanoseconds < deadline && line.count < 16 * 1024 {
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                if byte == 10 { complete = true; break }
                line.append(byte)
            } else if count == 0 { break }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 50)
            } else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        guard complete, let info = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let port = info["port"] as? Int, let type = info["keyType"] as? String,
              let key = info["publicKey"] as? String else {
            let diagnostic = String(decoding: (try? Data(contentsOf: diagnosticURL))?.prefix(4096) ?? Data(), as: UTF8.self)
                .replacingOccurrences(of: password, with: "[redacted]")
            throw SFTPError.transport("Password fixture did not become ready within 10 seconds (maximum 16 KiB readiness record). Set FAR_TEST_PYTHON to Python with test-only Paramiko installed. " + diagnostic)
        }
        keyType = type; publicKey = key
        connection = NetworkConnection(kind: .sftp, host: "127.0.0.1", port: port, username: "fixture", timeoutSeconds: 3, sftpAuthenticationMode: .password)
        store = SFTPHostKeyStore(url: root.appendingPathComponent("known_hosts"))
        ready = true
    }
    func trust() throws { try store.trust(SFTPHostKey(host: connection.host, port: connection.port, keyType: keyType, publicKey: publicKey)) }
    func stop() {
        stopPasswordFixtureProcess(server)
        try? FileManager.default.removeItem(at: root)
    }
    deinit { stop() }
}

private func askpassDirectories() -> Set<String> {
    Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
        .filter { $0.hasPrefix("farmac-askpass-") })
}

private func stopPasswordFixtureProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

extension SFTPPasswordTests {
    @Test func remoteTreeMoveAndDeleteUseRealSFTPNonglobalCommands() throws {
        let f = try PasswordSSHFixture(); defer { f.stop() }; try f.trust()
        let p = f.provider, token = TransferCancellation()
        try p.makeDirectory(path: "/tree", cancellation: token)
        try p.makeDirectory(path: "/tree/sub", cancellation: token)
        let local = f.root.appendingPathComponent("upload")
        try Data("tree bytes".utf8).write(to: local)
        try p.upload(from: local, to: "/tree/sub/file", cancellation: token, progress: { _ in })
        let source = try #require(try p.stat(path: "/tree", cancellation: token))
        let plan = try RemoteTreeOperations.prepareMove(provider: p, entries: [source], to: "/renamed", intoDirectory: false)
        let moved = try RemoteTreeOperations.move(provider: p, plan: plan)
        #expect(moved.completed.count == 1)
        #expect(try p.stat(path: "/renamed/sub/file", cancellation: token)?.size == 10)
        let root = try #require(try p.stat(path: "/renamed", cancellation: token))
        let preview = try RemoteTreeOperations.prepareDelete(provider: p, entries: [root])
        // Change the server filesystem after read-only preview, before confirmation.
        try Data("new child".utf8).write(to: f.root.appendingPathComponent("renamed/new"))
        #expect(throws: RemoteTreeOperationError.self) { try RemoteTreeOperations.delete(provider: p, plan: preview) }
        #expect(try p.stat(path: "/renamed/sub/file", cancellation: token) != nil)
        #expect(throws: (any Error).self) { try p.remove(path: "/renamed", isDirectory: true, cancellation: token) }
        #expect(try p.stat(path: "/renamed/new", cancellation: token) != nil)
        let fresh = try RemoteTreeOperations.prepareDelete(provider: p, entries: [try #require(try p.stat(path: "/renamed", cancellation: token))])
        let deleted = try RemoteTreeOperations.delete(provider: p, plan: fresh)
        #expect(deleted.completed.count == 4)
        #expect(try p.stat(path: "/renamed", cancellation: token) == nil)
        #expect(try Data(contentsOf: local) == Data("tree bytes".utf8))
    }
}

extension SFTPPasswordTests {
    @Test func localAndSFTPTreeMoveRoundTripPreservesBytesEmptyFoldersAndReusesAuthentication() throws {
        let f = try PasswordSSHFixture(); defer { f.stop() }; try f.trust()
        let p = f.provider; defer { p.closeConnection() }
        let token = TransferCancellation(), fm = FileManager.default
        let source = f.root.appendingPathComponent("local/moving-tree")
        try fm.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let bytes = Data("SFTP tree MOVE — Привет 🐈".utf8)
        try bytes.write(to: source.appendingPathComponent("sub/file.txt"))
        try p.makeDirectory(path: "/remote", cancellation: token)
        let upload = try RemoteDirectoryTransfer.prepareUpload(provider: p, sources: [source], into: "/remote", policy: .requireNew)
        let sent = try RemoteDirectoryTransfer.move(provider: p, plan: upload)
        #expect(sent.moving && sent.retainedSources.isEmpty && sent.failedSourceRemovals.isEmpty)
        #expect(!fm.fileExists(atPath: source.path))
        #expect(try p.stat(path: "/remote/moving-tree/empty", cancellation: token)?.isDirectory == true)
        let remote = try #require(try p.stat(path: "/remote/moving-tree", cancellation: token))
        let destination = f.root.appendingPathComponent("downloads")
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let download = try RemoteDirectoryTransfer.prepareDownload(provider: p, entries: [remote], into: destination, policy: .requireNew)
        let received = try RemoteDirectoryTransfer.move(provider: p, plan: download)
        #expect(received.moving && received.retainedSources.isEmpty && received.failedSourceRemovals.isEmpty)
        #expect(try Data(contentsOf: destination.appendingPathComponent("moving-tree/sub/file.txt")) == bytes)
        var directory: ObjCBool = false
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("moving-tree/empty").path, isDirectory: &directory) && directory.boolValue)
        #expect(try p.stat(path: remote.path, cancellation: token) == nil)
        #expect(f.authCount == 1)
    }
}
