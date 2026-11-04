import Foundation
import Darwin

/// A failed jump is distinct from a failed target, so trust approval always names
/// the server whose key was actually rejected. Indices refer to the saved route.
public struct SFTPJumpHostError: LocalizedError, Equatable {
    public let index: Int
    public let error: SFTPError
    public init(index: Int, error: SFTPError) { self.index = index; self.error = error }
    public var errorDescription: String? { "SSH-переход \(index + 1): \(error.localizedDescription)" }
}

/// Each process authenticates one jump locally and forwards only the next SSH
/// endpoint. Neither the target password nor its askpass bridge reaches a jump.
/// A chain belongs to exactly one reusable SFTP session or one untrusted key scan.
final class SFTPTunnelChain {
    private(set) var host: String
    private(set) var port: Int
    private var processes: [SFTPProcess] = []
    private var directory: URL?
    private let deadline: TimeInterval
    var remainingTimeout: Double { max(0.001, deadline - ProcessInfo.processInfo.systemUptime) }

    init(connection: NetworkConnection, knownHostsURL: URL, cancellation: TransferCancellation, authenticationHandler: SFTPAuthenticationHandler? = nil, connectionCancellation: TransferCancellation? = nil) throws {
        host = connection.host; port = connection.port
        deadline = ProcessInfo.processInfo.systemUptime + connection.timeoutSeconds
        try SFTPProvider.validate(connection)
        guard !cancellation.isCancelled, connectionCancellation?.isCancelled != true else { throw SFTPError.cancelled }
        guard !connection.sftpJumpHosts.isEmpty else { return }
        do {
            // Short absolute path stays below macOS's Unix-domain socket limit.
            let directory = URL(fileURLWithPath: "/private/tmp/farmac-jump-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.directory = directory
            for (index, jump) in connection.sftpJumpHosts.enumerated() {
                guard !cancellation.isCancelled, connectionCancellation?.isCancelled != true else { throw SFTPError.cancelled }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw SFTPError.timedOut }
                let nextHost = index + 1 < connection.sftpJumpHosts.count ? connection.sftpJumpHosts[index + 1].host : connection.host
                let nextPort = index + 1 < connection.sftpJumpHosts.count ? connection.sftpJumpHosts[index + 1].port : connection.port
                let localPort = try Self.unusedLoopbackPort()
                let controlURL = directory.appendingPathComponent("c\(index)")
                let endpointHost = index == 0 ? jump.host : "127.0.0.1"
                let endpointPort = index == 0 ? jump.port : port
                do {
                    let args = try Self.arguments(jump: jump, endpointHost: endpointHost, endpointPort: endpointPort,
                                                  nextHost: nextHost, nextPort: nextPort, localPort: localPort,
                                                  knownHostsURL: knownHostsURL, controlURL: controlURL, timeout: remainingTimeout)
                    let process = try SFTPProcess(executable: "/usr/bin/ssh", arguments: args,
                                                  cancellation: cancellation, timeout: remainingTimeout, connectionCancellation: connectionCancellation,
                                                  authenticationEndpoint: jump.authenticationMode == .keyAgent ? nil : SFTPAuthenticationEndpoint(host: jump.host, port: jump.port, username: jump.username, jumpHostIndex: index),
                                                  authenticationHandler: authenticationHandler)
                    processes.append(process)
                    try process.waitForTunnel(controlURL: controlURL)
                } catch let error as SFTPError {
                    if error == .cancelled || error == .timedOut { throw error }
                    throw SFTPJumpHostError(index: index, error: error)
                }
                host = "127.0.0.1"; port = localPort
            }
        } catch { stop(); throw error }
    }

    static func arguments(jump: SFTPJumpHost, endpointHost: String, endpointPort: Int, nextHost: String, nextPort: Int,
                          localPort: Int, knownHostsURL: URL, controlURL: URL, timeout: Double) throws -> [String] {
        let connection = NetworkConnection(kind: .sftp, host: jump.host, port: jump.port, username: jump.username,
                                           privateKeyPath: jump.privateKeyPath, timeoutSeconds: timeout, sftpAuthenticationMode: jump.authenticationMode)
        guard SFTPProvider.validHost(endpointHost), SFTPProvider.validHost(nextHost),
              (1...65535).contains(endpointPort), (1...65535).contains(nextPort), (1...65535).contains(localPort) else {
            throw SFTPError.invalidConfiguration
        }
        var args = try SFTPProvider.sshOptions(connection: connection, knownHostsURL: knownHostsURL,
                                               passwordAuthentication: jump.authenticationMode == .password, endpointPort: endpointPort)
        // ExitOnForwardFailure prevents readiness if the short reservation race
        // loses its port. The private control socket proves this process owns
        // the listener; a pre-existing unrelated loopback listener is not ready.
        let forwardedHost = nextHost.contains(":") ? "[\(nextHost)]" : nextHost
        args += ["-N", "-n", "-L", "127.0.0.1:\(localPort):\(forwardedHost):\(nextPort)",
                 "-o", "ExitOnForwardFailure=yes", "-o", "GatewayPorts=no", "-o", "ForwardAgent=no",
                 "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-S", controlURL.path, "--", endpointHost]
        return args
    }

    var isRunning: Bool { processes.allSatisfy(\.isRunning) }
    func bind(cancellation: TransferCancellation, connectionCancellation: TransferCancellation) {
        for process in processes { process.bind(cancellation: cancellation, connectionCancellation: connectionCancellation) }
    }
    func unbind() { for process in processes { process.unbind() } }
    func stop() {
        for process in processes.reversed() { process.stop() }
        processes.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    deinit { stop() }

    private static func unusedLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
