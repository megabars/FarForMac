import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite(.serialized)
struct SFTPJumpHostTests {
    @Test func targetTunnelKeepsOriginalPinAndPasswordIsolation() throws {
        var connection = NetworkConnection(kind: .sftp, host: "target.internal", port: 2022, username: "target-user", privateKeyPath: "/tmp/target-key")
        connection.sftpJumpHosts = [SFTPJumpHost(host: "jump.internal", username: "jump-user", privateKeyPath: "/tmp/jump-key")]
        let arguments = try SFTPProvider.sshArguments(connection: connection, knownHostsURL: URL(fileURLWithPath: "/tmp/known hosts"),
                                                      passwordAuthentication: true, endpointHost: "127.0.0.1", endpointPort: 54321)
        #expect(arguments.contains("HostKeyAlias=[target.internal]:2022"))
        #expect(arguments.contains("54321"))
        #expect(Array(arguments.suffix(3)) == ["--", "127.0.0.1", "sftp"])
        #expect(!arguments.contains("/tmp/target-key"))
        #expect(!arguments.contains("/tmp/jump-key"))
        #expect(arguments.contains("PubkeyAuthentication=no"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
    }

    @Test func hopIsKeyOnlyAndPinsItsOwnEndpointWithoutAgentForwarding() throws {
        let jump = SFTPJumpHost(host: "jump.internal", port: 2222, username: "jump-user", privateKeyPath: "/tmp/jump key")
        let arguments = try SFTPTunnelChain.arguments(jump: jump, endpointHost: "127.0.0.1", endpointPort: 54321,
            nextHost: "2001:db8::5", nextPort: 22, localPort: 54322,
            knownHostsURL: URL(fileURLWithPath: "/tmp/known hosts"), controlURL: URL(fileURLWithPath: "/private/tmp/control"), timeout: 3)
        for option in ["HostKeyAlias=[jump.internal]:2222", "StrictHostKeyChecking=yes", "BatchMode=yes", "PasswordAuthentication=no",
                       "KbdInteractiveAuthentication=no", "PreferredAuthentications=publickey", "ForwardAgent=no",
                       "ControlPersist=no", "ExitOnForwardFailure=yes", "GatewayPorts=no", "/tmp/jump key",
                       "127.0.0.1:54322:[2001:db8::5]:22"] { #expect(arguments.contains(option)) }
        #expect(Array(arguments.prefix(2)) == ["-F", "/dev/null"])
        #expect(Array(arguments.suffix(2)) == ["--", "127.0.0.1"])
        #expect(arguments.contains("-N")); #expect(!arguments.contains("-s"))
        #expect(!arguments.contains(where: { $0.hasPrefix("ProxyCommand") || $0.hasPrefix("LocalCommand") }))
    }

    @Test func validatesEveryHopBeforeStartingProcesses() throws {
        var connection = NetworkConnection(kind: .sftp, host: "target.internal", username: "target")
        let host = SFTPJumpHost(host: "jump.internal", username: "jump")
        connection.sftpJumpHosts = Array(repeating: host, count: 5)
        #expect(throws: SFTPError.invalidConfiguration) { try SFTPProvider.validate(connection) }
        for badHost in ["-oProxyCommand=bad", "jump\nHost *", "jump;touch", "jump/path"] {
            connection.sftpJumpHosts = [SFTPJumpHost(host: badHost, username: "jump")]
            #expect(throws: SFTPError.invalidConfiguration) { try SFTPProvider.validate(connection) }
        }
        connection.sftpJumpHosts = [SFTPJumpHost(host: "jump.internal", port: 0, username: "jump")]
        #expect(throws: SFTPError.invalidConfiguration) { try SFTPProvider.validate(connection) }
        connection.sftpJumpHosts = [SFTPJumpHost(host: "jump.internal", username: "jump\nuser")]
        #expect(throws: SFTPError.invalidConfiguration) { try SFTPProvider.validate(connection) }
        connection.sftpJumpHosts = [SFTPJumpHost(host: "jump.internal", username: "jump", privateKeyPath: "relative/key")]
        #expect(throws: SFTPError.invalidConfiguration) { try SFTPProvider.validate(connection) }
        connection.sftpJumpHosts = [host]
        let cancellation = TransferCancellation(); cancellation.cancel()
        #expect(throws: SFTPError.cancelled) {
            _ = try SFTPTunnelChain(connection: connection, knownHostsURL: URL(fileURLWithPath: "/tmp/unused-hosts"), cancellation: cancellation)
        }
        #expect(throws: SFTPError.invalidConfiguration) {
            _ = try SFTPHostKeyStore(url: URL(fileURLWithPath: "/tmp/unused-hosts")).probe(connection: connection, jumpHostIndex: 1, cancellation: TransferCancellation())
        }
    }

    @Test func directProviderValidationRejectsCyclesAndBadTargetMetadata() throws {
        let valid = NetworkConnection(kind: .sftp, host: "target.internal", port: 2022, username: "target", timeoutSeconds: 0.15)
        try SFTPProvider.validate(valid) // Request deadlines intentionally allow subsecond values.
        var connection = valid
        connection.sftpJumpHosts = [SFTPJumpHost(host: "TARGET.internal", port: 2022, username: "jump")]
        #expect(throws: SFTPError.invalidConfiguration) { try SFTPProvider.validate(connection) }
        connection.sftpJumpHosts = [SFTPJumpHost(host: "jump.internal", username: "first"), SFTPJumpHost(host: "JUMP.internal", username: "second")]
        #expect(throws: SFTPError.invalidConfiguration) { try SFTPProvider.validate(connection) }
        connection = valid
        for keyPath in ["relative/key", "/tmp/key\0suffix", "/tmp/key\n", "/tmp/key\r"] {
            connection.privateKeyPath = keyPath
            #expect(throws: SFTPError.invalidConfiguration) { try SFTPProvider.validate(connection) }
        }
        connection = valid
        for username in ["", "user name", "user\tname", "user\u{7F}", String(repeating: "u", count: 257)] {
            connection.username = username
            #expect(throws: SFTPError.invalidConfiguration) { try SFTPProvider.validate(connection) }
        }
        connection = valid
        for host in [String(repeating: "h", count: 254), "host_name", "host name"] {
            connection.host = host
            #expect(throws: SFTPError.invalidConfiguration) { try SFTPProvider.validate(connection) }
        }
    }

    @Test func tunnelEndpointOverridesAreValidatedBeforeCreatingArguments() throws {
        let connection = NetworkConnection(kind: .sftp, host: "target.internal", username: "target")
        let store = URL(fileURLWithPath: "/tmp/unused-hosts")
        for host in ["", "-oProxyCommand=bad", "127.0.0.1\n", String(repeating: "h", count: 254)] {
            #expect(throws: SFTPError.invalidConfiguration) {
                _ = try SFTPProvider.sshArguments(connection: connection, knownHostsURL: store, endpointHost: host)
            }
        }
        for port in [0, -1, 65536] {
            #expect(throws: SFTPError.invalidConfiguration) {
                _ = try SFTPProvider.sshArguments(connection: connection, knownHostsURL: store, endpointPort: port)
            }
        }
    }

    @Test func tunnelReadinessIsBoundedAndStoppingReapsChild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("farmac-jump-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidURL = directory.appendingPathComponent("pid")
        let process = try SFTPProcess(executable: "/bin/sh", arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 20", "test", pidURL.path],
                                      cancellation: TransferCancellation(), timeout: 0.15)
        defer { process.stop() }
        let start = Date()
        #expect(throws: SFTPError.timedOut) { try process.waitForTunnel(controlURL: directory.appendingPathComponent("absent-control")) }
        let pid = try #require(Int32(try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Deadline failure now reaps the process before releasing askpass helpers.
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        process.stop(); process.stop()
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func transportLaunchedAndStoppedOnDifferentWorkersIsBoundedAndReaped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("farmac-cross-thread-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for iteration in 0..<12 {
            let state = CrossThreadTransport(), pidURL = directory.appendingPathComponent("pid-\(iteration)")
            let mode = iteration % 3
            Thread.detachNewThread {
                do {
                    let action = mode == 0 ? "exec /bin/sleep 20" : mode == 1 ? "trap '' TERM; exec /bin/sleep 20" : "exit 0"
                    let process = try SFTPProcess(executable: "/bin/sh", arguments: ["-p", "-c", "echo $$ > \"$1\"; printf X; " + action, "test", pidURL.path],
                                                  cancellation: TransferCancellation(), timeout: 1)
                    _ = try process.read(1)
                    state.store(process)
                } catch { state.fail(error.localizedDescription) }
                state.launched.signal()
            }
            try #require(state.launched.wait(timeout: .now() + 2) == .success)
            #expect(state.error == nil)
            let process = try #require(state.process)
            let pid = try #require(Int32(try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            // Let the launching worker return; the natural-exit variant also
            // exercises stop after Foundation has already collected the child.
            Thread.sleep(forTimeInterval: 0.02)
            let stopped = DispatchSemaphore(value: 0), start = ProcessInfo.processInfo.systemUptime
            Thread.detachNewThread { process.stop(); process.stop(); stopped.signal() }
            try #require(stopped.wait(timeout: .now() + 2) == .success)
            #expect(ProcessInfo.processInfo.systemUptime - start < 1)
            #expect(kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

}


private final class CrossThreadTransport {
    let launched = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: SFTPProcess?
    private var failure: String?
    var process: SFTPProcess? { lock.lock(); defer { lock.unlock() }; return value }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    func store(_ process: SFTPProcess) { lock.lock(); value = process; lock.unlock() }
    func fail(_ text: String) { lock.lock(); failure = text; lock.unlock() }
}
