import Foundation
import Darwin
import Testing
@testable import FarCore

// Shared serialized suite avoids racing askpass resource assertions in password tests.
extension SFTPPasswordTests {
    @Test func twoJumpHostsTransferRealSFTPAndKeepTargetPasswordSeparate() throws {
        let f = try JumpSSHFixture(); defer { f.stop() }
        try f.trustAll()
        let token = TransferCancellation()
        let provider = f.provider
        #expect(try provider.list(path: "/", cancellation: token).contains { $0.name == "hello.txt" })
        let bytes = Data("Данные через два SSH-сервера 🐈".utf8)
        let source = f.root.appendingPathComponent("source")
        try bytes.write(to: source)
        try provider.upload(from: source, to: "/new.txt", cancellation: token) { _ in }
        let destination = f.root.appendingPathComponent("result")
        try provider.download(path: "/new.txt", to: destination, resumeOffset: 0, cancellation: token) { _ in }
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(f.counter("target", "password") == 1)
        #expect(f.counter("jump1", "password") == 0)
        #expect(f.counter("jump2", "password") == 0)
        #expect(f.counter("jump1", "forward") > 0 && f.counter("jump2", "forward") > 0)
        provider.closeConnection()
        #expect(f.waitUntilDisconnected())
    }

    @Test func eachHopAndTargetRequireSeparateTrustAndProbeUsesRoute() throws {
        let f = try JumpSSHFixture(); defer { f.stop() }
        let token = TransferCancellation()
        for index in 0..<2 {
            do {
                _ = try f.provider.list(path: "/", cancellation: token)
                Issue.record("Untrusted jump accepted")
            } catch let error as SFTPJumpHostError {
                #expect(error.index == index)
                #expect(error.error == .unknownHostKey)
            }
            #expect(f.counter("target", "password") == 0)
            let keys = try f.store.probe(connection: f.connection, jumpHostIndex: index, cancellation: token)
            let expected = f.key(index == 0 ? "jump1" : "jump2")
            #expect(keys.contains { $0.host == expected.host && $0.port == expected.port && $0.publicKey == expected.publicKey })
            try f.store.trust(expected)
        }
        #expect(throws: SFTPError.unknownHostKey) { _ = try f.provider.list(path: "/", cancellation: token) }
        #expect(f.counter("target", "password") == 0)
        let keys = try f.store.probe(connection: f.connection, cancellation: token)
        #expect(keys.contains { $0.host == "target.farmac.invalid" && $0.publicKey == f.key("target").publicKey })
        #expect(f.counter("target", "password") == 0)
        try f.store.trust(f.key("target"))
        #expect(try f.provider.stat(path: "/hello.txt", cancellation: token) != nil)
        #expect(f.waitUntilDisconnected())
    }

    @Test func changedJumpKeyStopsBeforeTargetAuthentication() throws {
        let f = try JumpSSHFixture(); defer { f.stop() }
        try f.trustAll()
        let jump = f.key("jump2"), other = f.key("target")
        try f.store.trust(SFTPHostKey(host: jump.host, port: jump.port, keyType: other.keyType, publicKey: other.publicKey))
        do {
            _ = try f.provider.list(path: "/", cancellation: TransferCancellation())
            Issue.record("Changed jump key accepted")
        } catch let error as SFTPJumpHostError {
            #expect(error.index == 1)
            #expect(error.error == .changedHostKey)
        }
        #expect(f.counter("target", "password") == 0)
        #expect(f.counter("jump2", "password") == 0)
        #expect(f.waitUntilDisconnected())
    }

    @Test func jumpRouteTimeoutAndCancellationCloseAllTransports() throws {
        let f = try JumpSSHFixture(jumpDelay: 2); defer { f.stop() }; try f.trustAll()
        var connection = f.connection; connection.timeoutSeconds = 0.25
        let timed = SFTPProvider(connection: connection, password: f.password, knownHostsURL: f.store.url)
        #expect(throws: SFTPError.timedOut) { _ = try timed.list(path: "/", cancellation: TransferCancellation()) }
        let token = TransferCancellation()
        Thread.detachNewThread { Thread.sleep(forTimeInterval: 0.2); token.cancel() }
        #expect(throws: SFTPError.cancelled) { _ = try f.provider.list(path: "/", cancellation: token) }
        #expect(f.counter("target", "password") == 0)
        #expect(f.counter("jump1", "password") == 0)
        #expect(f.waitUntilDisconnected(timeout: 4))
    }

    @Test func targetKeyChangeBehindJumpsIsRejectedBeforePassword() throws {
        let f = try JumpSSHFixture(); defer { f.stop() }; try f.trustAll()
        let target = f.key("target"), other = f.key("jump1")
        try f.store.trust(SFTPHostKey(host: target.host, port: target.port, keyType: other.keyType, publicKey: other.publicKey))
        #expect(throws: SFTPError.changedHostKey) { _ = try f.provider.list(path: "/", cancellation: TransferCancellation()) }
        #expect(f.counter("target", "password") == 0)
        #expect(f.waitUntilDisconnected())
    }

    @Test func cancellationDuringTargetAuthenticationClosesEstablishedJumpChain() throws {
        let f = try JumpSSHFixture(authDelay: 3); defer { f.stop() }; try f.trustAll()
        let token = TransferCancellation()
        Thread.detachNewThread {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while f.counter("target", "password") == 0 && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            token.cancel()
        }
        #expect(throws: SFTPError.cancelled) { _ = try f.provider.list(path: "/", cancellation: token) }
        #expect(f.counter("target", "password") == 1)
        #expect(f.counter("jump1", "password") == 0 && f.counter("jump2", "password") == 0)
        #expect(f.waitUntilDisconnected(timeout: 4))
    }

    @Test func importedSSHConfigConnectsThroughDeclaredProxyJumpChain() throws {
        let f = try JumpSSHFixture(); defer { f.stop() }; try f.trustAll()
        let config = f.root.appendingPathComponent("config")
        try """
        Host test-target
            HostName target.farmac.invalid
            User fixture
            Port \(f.port("target"))
            ProxyJump first,second
        Host first
            HostName 127.0.0.1
            User fixture
            Port \(f.port("jump1"))
            IdentityFile "\(f.identity)"
        Host second
            HostName jump2.farmac.invalid
            User fixture
            Port \(f.port("jump2"))
            IdentityFile "\(f.identity)"
        """.write(to: config, atomically: true, encoding: .utf8)
        var imported = try SSHConfiguration.importConnection(alias: "test-target", from: config)
        #expect(imported.sftpJumpHosts == f.connection.sftpJumpHosts)
        imported.sftpAuthenticationMode = .password
        let provider = SFTPProvider(connection: imported, password: f.password, knownHostsURL: f.store.url)
        #expect(try provider.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        #expect(f.counter("jump1", "password") == 0 && f.counter("jump2", "password") == 0)
        provider.closeConnection()
        #expect(f.waitUntilDisconnected())
    }
}

final class JumpSSHFixture {
    let root: URL
    let server = Process()
    let password = "Target-only пароль $(literal) 🔐"
    let jumpPasswords = ["First-hop пароль ; $(literal) 🐈", "Second-hop пароль ' $(literal) 🌙"]
    let otp = "123456"
    let confirmation = "654321"
    let info: [String: Any]
    let connection: NetworkConnection
    let store: SFTPHostKeyStore
    var identity: String { info["identity"] as! String }
    var provider: SFTPProvider { SFTPProvider(connection: connection, password: password, knownHostsURL: store.url) }

    init(jumpDelay: Double = 0, authDelay: Double = 0, targetMode: String = "password", jumpModes: [String] = ["publickey", "publickey"]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("farmac-jump-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("NetworkFixtures/ssh_jump_fixture.py")
        let process = server, rootURL = root
        var ready = false
        defer { if !ready { stopJumpFixture(process); try? FileManager.default.removeItem(at: rootURL) } }
        let input = Pipe(), output = Pipe()
        let diagnostic = root.appendingPathComponent("startup.log")
        _ = FileManager.default.createFile(atPath: diagnostic.path, contents: nil)
        let log = try FileHandle(forWritingTo: diagnostic); defer { try? log.close() }
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = [ProcessInfo.processInfo.environment["FAR_TEST_PYTHON"] ?? "python3", fixture.path, root.path]
        server.standardInput = input; server.standardOutput = output; server.standardError = log
        try server.run()
        let endpoints: [String: Any] = [
            "target": ["mode": targetMode, "password": password, "otp": otp, "confirmation": confirmation],
            "jump1": ["mode": jumpModes[0], "password": jumpPasswords[0], "otp": otp, "confirmation": confirmation],
            "jump2": ["mode": jumpModes[1], "password": jumpPasswords[1], "otp": otp, "confirmation": confirmation]
        ]
        var options = try JSONSerialization.data(withJSONObject: ["password": password, "jumpDelay": jumpDelay, "authDelay": authDelay, "endpoints": endpoints])
        options.append(10)
        try input.fileHandleForWriting.write(contentsOf: options)
        try input.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var line = Data(), complete = false
        while ProcessInfo.processInfo.systemUptime < deadline && line.count < 16 * 1024 {
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                if byte == 10 { complete = true; break }; line.append(byte)
            } else if count == 0 { break }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0); _ = poll(&p, 1, 50)
            } else { throw POSIXError(.EIO) }
        }
        guard complete, let info = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              let target = info["target"] as? [String: Any], let targetPort = target["port"] as? Int,
              let jump1 = info["jump1"] as? [String: Any], let p1 = jump1["port"] as? Int,
              let jump2 = info["jump2"] as? [String: Any], let p2 = jump2["port"] as? Int,
              let identity = info["identity"] as? String else {
            let error = String(decoding: (try? Data(contentsOf: diagnostic))?.prefix(4096) ?? Data(), as: UTF8.self)
                .replacingOccurrences(of: password, with: "[redacted]")
            throw SFTPError.transport("SSH jump fixture did not start; FAR_TEST_PYTHON needs test-only Paramiko. " + error)
        }
        self.info = info
        func authentication(_ mode: String) -> SFTPAuthenticationMode {
            mode == "password" ? .password : mode == "publickey" ? .keyAgent : .interactive
        }
        connection = NetworkConnection(kind: .sftp, host: "target.farmac.invalid", port: targetPort, username: "fixture", privateKeyPath: targetMode == "keyOTP" ? identity : nil, timeoutSeconds: 5, sftpAuthenticationMode: authentication(targetMode),
            sftpJumpHosts: [SFTPJumpHost(host: "127.0.0.1", port: p1, username: "fixture", privateKeyPath: identity, authenticationMode: authentication(jumpModes[0])),
                           SFTPJumpHost(host: "jump2.farmac.invalid", port: p2, username: "fixture", privateKeyPath: identity, authenticationMode: authentication(jumpModes[1]))])
        store = SFTPHostKeyStore(url: root.appendingPathComponent("known_hosts"))
        ready = true
    }
    func port(_ name: String) -> Int { (info[name] as! [String: Any])["port"] as! Int }
    func key(_ name: String) -> SFTPHostKey {
        let endpoint = info[name] as! [String: Any]
        let host = name == "jump1" ? "127.0.0.1" : name == "jump2" ? "jump2.farmac.invalid" : "target.farmac.invalid"
        return SFTPHostKey(host: host, port: port(name), keyType: endpoint["keyType"] as! String, publicKey: endpoint["publicKey"] as! String)
    }
    func trustAll() throws { for name in ["jump1", "jump2", "target"] { try store.trust(key(name)) } }
    func counter(_ endpoint: String, _ name: String) -> Int {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("stats.json")),
              let stats = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Int]] else { return -1 }
        return stats[endpoint]?[name] ?? -1
    }
    func waitUntilDisconnected(timeout: Double = 2) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if ["jump1", "jump2", "target"].allSatisfy({ counter($0, "active") == 0 }) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }
    func stop() { stopJumpFixture(server); try? FileManager.default.removeItem(at: root) }
    deinit { stop() }
}
private func stopJumpFixture(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}
