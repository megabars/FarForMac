import Foundation
import Darwin
import CryptoKit

public enum SFTPError: LocalizedError, Equatable {
    case invalidPassword
    case invalidConfiguration, malformedPacket, unsupportedVersion, cancelled, timedOut
    case transport(String), status(UInt32, String), unsupported(String)
    case unknownHostKey, changedHostKey, authenticationFailed
    public var errorDescription: String? {
        switch self {
        case .invalidPassword: return "Ответ SSH (пароль или код) должен занимать не более 1023 байт UTF-8 и не содержать NUL или переводы строк."
        case .invalidConfiguration: return "Проверьте адрес, порт и имя пользователя SFTP."
        case .malformedPacket: return "Сервер вернул некорректный пакет SFTP."
        case .unsupportedVersion: return "Сервер не поддерживает SFTP версии 3."
        case .cancelled: return "Операция отменена."
        case .timedOut: return "Время ожидания SFTP истекло."
        case .unknownHostKey: return "Ключ сервера ещё не подтверждён. Сравните отпечаток с владельцем сервера."
        case .changedHostKey: return "Ключ сервера изменился. Проверьте замену ключа у владельца сервера."
        case .authenticationFailed: return "Сервер отклонил пароль, SSH-ключ или код подтверждения. Проверьте данные подключения."
        case .transport(let text): return "Не удалось подключиться по SFTP: \(text)"
        case .status(let code, let text): return "SFTP (\(code)): \(text)"
        case .unsupported(let text): return text
        }
    }
}

/// Scanned keys are untrusted until the user compares the fingerprint and explicitly trusts one.
public struct SFTPHostKey: Identifiable, Hashable, Sendable {
    public var id: String { "\(host):\(port):\(keyType):\(publicKey)" }
    public let host: String
    public let port: Int
    public let keyType: String
    public let publicKey: String
    public var fingerprint: String {
        let digest = SHA256.hash(data: Data(base64Encoded: publicKey) ?? Data())
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    public init(host: String, port: Int, keyType: String, publicKey: String) {
        self.host = host; self.port = port; self.keyType = keyType; self.publicKey = publicKey
    }
    fileprivate var line: String { "[\(host)]:\(port) \(keyType) \(publicKey)" }
}

public final class SFTPHostKeyStore {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FarForMac/Network/known_hosts")
    }
    public let url: URL
    private let lock = NSLock()
    public init(url: URL = SFTPHostKeyStore.defaultURL) { self.url = url }
    /// Never writes known_hosts. The UI must display the returned fingerprint before calling trust.
    public func probe(connection: NetworkConnection, jumpHostIndex: Int? = nil, cancellation: TransferCancellation, authenticationHandler: SFTPAuthenticationHandler? = nil) throws -> [SFTPHostKey] {
        try SFTPProvider.validate(connection)
        var scannedConnection = connection
        if let index = jumpHostIndex {
            guard connection.sftpJumpHosts.indices.contains(index) else { throw SFTPError.invalidConfiguration }
            let jump = connection.sftpJumpHosts[index]
            scannedConnection.host = jump.host; scannedConnection.port = jump.port; scannedConnection.username = jump.username
            scannedConnection.privateKeyPath = jump.privateKeyPath
            scannedConnection.sftpJumpHosts = Array(connection.sftpJumpHosts.prefix(index))
        }
        let tunnels = try SFTPTunnelChain(connection: scannedConnection, knownHostsURL: url, cancellation: cancellation, authenticationHandler: authenticationHandler)
        defer { tunnels.stop() }
        let transport = try SFTPProcess(executable: "/usr/bin/ssh-keyscan",
            arguments: ["-T", String(max(1, Int(connection.timeoutSeconds))), "-p", String(tunnels.port), "-t", "ed25519,ecdsa,rsa", tunnels.host],
            cancellation: cancellation, timeout: tunnels.remainingTimeout)
        defer { transport.stop() }
        let data = try transport.readToEnd(limit: 256 * 1024)
        let keys = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> SFTPHostKey? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, !line.hasPrefix("#"), Data(base64Encoded: String(fields[2])) != nil else { return nil }
            return SFTPHostKey(host: scannedConnection.host, port: scannedConnection.port, keyType: String(fields[1]), publicKey: String(fields[2]))
        }
        guard !keys.isEmpty else { throw SFTPError.transport(transport.errorText) }
        return Array(Set(keys)).sorted { $0.keyType < $1.keyType }
    }
    /// Explicit user approval only; existing pins for the same host/key type are replaced.
    public func trust(_ key: SFTPHostKey) throws {
        guard SFTPProvider.validHost(key.host), (1...65535).contains(key.port),
              ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"].contains(key.keyType),
              let blob = Data(base64Encoded: key.publicKey), !blob.isEmpty else { throw SFTPError.invalidConfiguration }
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let prefix = "[\(key.host)]:\(key.port) \(key.keyType) "
        let lines = old.split(separator: "\n").map(String.init).filter { !$0.hasPrefix(prefix) }
        try (lines + [key.line]).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// SFTP v3 over the OpenSSH subsystem. No remote shell or textual directory listing is used.
/// Authentication uses a supplied target password, ssh-agent / identities, or per-round interactive answers.
public final class SFTPProvider: RemoteSearchDownloadProvider, RemoteBoundedDownloadProvider {
    public let connection: NetworkConnection
    public let knownHostsURL: URL
    private let password: String?
    private let authenticationHandler: SFTPAuthenticationHandler?
    private let testCommand: (String, [String])?
    private let sessionCondition = NSCondition()
    private var cachedSession: SFTPSession?
    private var cachedTrust: Data?
    private var activeCancellation: TransferCancellation?
    private var activeThread: Thread?
    private var generation: UInt64 = 0

    /// Disconnects this provider only. An in-flight operation observes cancellation
    /// on its worker, so close is safe from an authentication/progress callback.
    /// A later explicit operation may establish a new authenticated connection.
    public func closeConnection() {
        sessionCondition.lock()
        generation &+= 1
        activeCancellation?.cancel()
        let idle = activeCancellation == nil ? cachedSession : nil
        if idle != nil { cachedSession = nil; cachedTrust = nil }
        sessionCondition.broadcast()
        sessionCondition.unlock()
        idle?.stop()
    }
    deinit { cachedSession?.stop() }

    // Immutable profile settings and secrets belong to this provider instance.
    // Read contents rather than timestamps: replacing a pin with equal-size bytes
    // or atomically replacing an identity must invalidate the authenticated session.
    private func trustSnapshot(_ cancellation: TransferCancellation, _ lifetime: TransferCancellation) throws -> Data {
        try SFTPTrustSnapshot.capture(knownHostsURL: knownHostsURL,
            identities: ([connection.privateKeyPath] + connection.sftpJumpHosts.map(\.privateKeyPath)).compactMap { $0 },
            cancellation: cancellation, connectionCancellation: lifetime, timeout: connection.timeoutSeconds)
    }
    private func withSession<T>(_ cancellation: TransferCancellation, _ operation: (SFTPSession) throws -> T) throws -> T {
        try Self.validate(connection)
        let waitDeadline = ProcessInfo.processInfo.systemUptime + connection.timeoutSeconds
        sessionCondition.lock()
        let waitingGeneration = generation
        while activeCancellation != nil {
            if cancellation.isCancelled || generation != waitingGeneration { sessionCondition.unlock(); throw SFTPError.cancelled }
            if activeThread === Thread.current { sessionCondition.unlock(); throw SFTPError.unsupported("Повторная команда SFTP из обработчика текущей операции недоступна.") }
            if ProcessInfo.processInfo.systemUptime >= waitDeadline { sessionCondition.unlock(); throw SFTPError.timedOut }
            _ = sessionCondition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        guard !cancellation.isCancelled, generation == waitingGeneration else { sessionCondition.unlock(); throw SFTPError.cancelled }
        let lifetime = TransferCancellation()
        activeCancellation = lifetime; activeThread = Thread.current
        let previous = cachedSession; cachedSession = nil
        let previousTrust = cachedTrust; cachedTrust = nil
        sessionCondition.unlock()
        var acquired: SFTPSession? = previous
        var reusable = false
        var snapshot = Data()
        defer {
            acquired?.unbind()
            sessionCondition.lock()
            if reusable && generation == waitingGeneration && !lifetime.isCancelled {
                // Publish idle ownership and release the lease atomically. A
                // concurrent disconnect must see either the active token or the
                // cached session, never an idle session behind an active lease.
                cachedSession = acquired; cachedTrust = snapshot
                activeCancellation = nil; activeThread = nil
                sessionCondition.broadcast(); sessionCondition.unlock()
            } else {
                // Stop before waking the next operation: old tunnel listeners
                // must be gone before a new connection can be established.
                sessionCondition.unlock()
                acquired?.stop()
                sessionCondition.lock()
                activeCancellation = nil; activeThread = nil
                sessionCondition.broadcast(); sessionCondition.unlock()
            }
        }
        snapshot = try trustSnapshot(cancellation, lifetime)
        if let previous, previousTrust == snapshot, previous.isRunning {
            acquired = previous
            previous.bind(cancellation: cancellation, connectionCancellation: lifetime)
        } else {
            previous?.stop()
            acquired = try createSession(cancellation, connectionCancellation: lifetime)
        }
        guard let acquired else { throw SFTPError.cancelled }
        do {
            let result = try operation(acquired)
            guard !cancellation.isCancelled, !lifetime.isCancelled else { throw SFTPError.cancelled }
            reusable = try acquired.isReusable && trustSnapshot(cancellation, lifetime) == snapshot
            return result
        } catch let error as SFTPError {
            // A complete STATUS failure leaves packet framing synchronized. Keep
            // authentication for ordinary permission/not-found errors if all
            // handles were closed, but never for transport/protocol failures.
            if case .status = error { reusable = try acquired.isReusable && trustSnapshot(cancellation, lifetime) == snapshot }
            throw error
        }
    }
    public init(connection: NetworkConnection, password: String? = nil, knownHostsURL: URL = SFTPHostKeyStore.defaultURL, authenticationHandler: SFTPAuthenticationHandler? = nil) {
        self.connection = connection; self.password = password; self.authenticationHandler = authenticationHandler; self.knownHostsURL = knownHostsURL; testCommand = nil
    }
    // Exercises the same binary engine against the shipped local sftp-server in tests.
    init(connection: NetworkConnection, subsystemExecutable: String, arguments: [String] = []) {
        self.connection = connection; password = nil; authenticationHandler = nil; knownHostsURL = SFTPHostKeyStore.defaultURL
        testCommand = (subsystemExecutable, arguments)
    }
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && !host.hasPrefix("-") && host.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || [45,46,58].contains($0)
        }
    }
    private static func validUsername(_ username: String) -> Bool {
        !username.isEmpty && username.utf8.count <= 256 && !username.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }
    private static func validPrivateKeyPath(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return true }
        return path.hasPrefix("/") && !path.contains("\0") && !path.contains(where: { $0.isNewline })
    }
    static func validate(_ c: NetworkConnection) throws {
        guard validHost(c.host), (1...65535).contains(c.port), validUsername(c.username), validPrivateKeyPath(c.privateKeyPath),
              c.timeoutSeconds.isFinite, c.timeoutSeconds > 0, c.timeoutSeconds <= 3600,
              c.sftpJumpHosts.count <= 4 else { throw SFTPError.invalidConfiguration }
        var endpoints: Set<String> = ["\(c.host.lowercased()):\(c.port)"]
        for jump in c.sftpJumpHosts {
            guard validHost(jump.host), (1...65535).contains(jump.port), validUsername(jump.username), validPrivateKeyPath(jump.privateKeyPath),
                  endpoints.insert("\(jump.host.lowercased()):\(jump.port)").inserted else { throw SFTPError.invalidConfiguration }
        }
    }
    static func sshArguments(connection c: NetworkConnection, knownHostsURL: URL, passwordAuthentication: Bool = false,
                             endpointHost: String? = nil, endpointPort: Int? = nil) throws -> [String] {
        guard validHost(endpointHost ?? c.host), (1...65535).contains(endpointPort ?? c.port) else { throw SFTPError.invalidConfiguration }
        var args = try sshOptions(connection: c, knownHostsURL: knownHostsURL, passwordAuthentication: passwordAuthentication,
                                  endpointPort: endpointPort ?? c.port)
        args += ["-s", "--", endpointHost ?? c.host, "sftp"]
        return args
    }
    static func sshOptions(connection c: NetworkConnection, knownHostsURL: URL, passwordAuthentication: Bool, endpointPort: Int) throws -> [String] {
        try validate(c)
        guard (1...65535).contains(endpointPort) else { throw SFTPError.invalidConfiguration }
        let interactive = c.sftpAuthenticationMode == .interactive
        let acceptsInput = passwordAuthentication || interactive
        // -F /dev/null also ignores system configuration, preventing ProxyCommand / LocalCommand hooks.
        var args = ["-F", "/dev/null", "-T", "-a", "-x", "-p", String(endpointPort), "-l", c.username,
                    "-o", "BatchMode=\(acceptsInput ? "no" : "yes")", "-o", "StrictHostKeyChecking=yes",
                    "-o", "UserKnownHostsFile=\"\(knownHostsURL.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"",
                    "-o", "GlobalKnownHostsFile=/dev/null", "-o", "HostKeyAlias=[\(c.host)]:\(c.port)",
                    "-o", "UpdateHostKeys=no", "-o", "VerifyHostKeyDNS=no", "-o", "CheckHostIP=no",
                    "-o", "PasswordAuthentication=\(passwordAuthentication ? "yes" : "no")", "-o", "KbdInteractiveAuthentication=\(interactive ? "yes" : "no")",
                    "-o", "PreferredAuthentications=\(interactive ? "publickey,keyboard-interactive" : passwordAuthentication ? "password" : "publickey")", "-o", "UseKeychain=\(acceptsInput ? "no" : "yes")",
                    "-o", "ConnectTimeout=\(max(1, Int(c.timeoutSeconds)))", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2"]
        if interactive { args += ["-o", "NumberOfPasswordPrompts=3", "-o", "AddKeysToAgent=no"] }
        if passwordAuthentication { args += ["-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"] }
        if !passwordAuthentication, let identity = c.privateKeyPath, !identity.isEmpty { args += ["-i", identity, "-o", "IdentitiesOnly=yes"] }
        return args
    }
    // Sessions accepting secrets never surface raw subprocess diagnostics: the bounded stderr
    // buffer may contain a truncated secret that exact-string redaction cannot remove.
    static func transportDiagnostics(_ rawText: String, passwordAuthentication: Bool) -> String {
        if passwordAuthentication { return "Соединение SSH закрыто. Проверьте пароль и доступность сервера." }
        return rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 16_384, !path.contains("\0") else {
            throw NetworkError.invalidPath(path)
        }
    }
    private func createSession(_ cancellation: TransferCancellation, connectionCancellation: TransferCancellation) throws -> SFTPSession {
        try Self.validate(connection)
        guard !connectionCancellation.isCancelled else { throw SFTPError.cancelled }
        let passwordMode = connection.sftpAuthenticationMode == .password
        if passwordMode && (password?.isEmpty ?? true) { throw SFTPError.invalidConfiguration }
        let sessionPassword = passwordMode ? password : nil
        if let command = testCommand {
            return try SFTPSession(executable: command.0, arguments: command.1, cancellation: cancellation,
                                  timeout: connection.timeoutSeconds, password: sessionPassword, connectionCancellation: connectionCancellation)
        }
        let handler = authenticationHandler
        var routedConnection = connection
        routedConnection.timeoutSeconds = connection.timeoutSeconds
        let tunnels = try SFTPTunnelChain(connection: routedConnection, knownHostsURL: knownHostsURL, cancellation: cancellation, authenticationHandler: handler, connectionCancellation: connectionCancellation)
        do {
            let arguments = try Self.sshArguments(connection: connection, knownHostsURL: knownHostsURL, passwordAuthentication: passwordMode,
                                                 endpointHost: tunnels.host, endpointPort: tunnels.port)
            return try SFTPSession(executable: "/usr/bin/ssh", arguments: arguments, cancellation: cancellation,
                                   timeout: connection.timeoutSeconds, password: sessionPassword, connectionCancellation: connectionCancellation,
                                   tunnels: tunnels, startupTimeout: tunnels.remainingTimeout,
                                   authenticationEndpoint: connection.sftpAuthenticationMode == .interactive ? SFTPAuthenticationEndpoint(host: connection.host, port: connection.port, username: connection.username) : nil,
                                   authenticationHandler: handler)
        } catch { tunnels.stop(); throw error }
    }
    public func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        try validatePath(path)
        return try withSession(cancellation) { s in
            let handle = try s.handle(type: 11, payload: SFTPPacket.string(path))
            defer { try? s.close(handle) }
            var result: [RemoteEntry] = []
            while true {
                var response = try s.request(12, SFTPPacket.string(handle), allowEOF: true)
                if response.type == 101 { break }
                guard response.type == 104 else { throw SFTPError.malformedPacket }
                let count = try response.uint32()
                guard count <= 100_000 else { throw SFTPError.malformedPacket }
                for _ in 0..<count {
                    let name = try response.text(); _ = try response.bytes() // longname is never parsed.
                    let attrs = try response.attributes()
                    guard name != ".", name != ".." else { continue }
                    guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { throw SFTPError.malformedPacket }
                    result.append(attrs.entry(path: (path.hasSuffix("/") ? path : path + "/") + name))
                }
                guard response.remaining == 0, result.count <= 1_000_000 else { throw SFTPError.malformedPacket }
            }
            return result
        }
    }
    public func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? {
        try validatePath(path)
        return try withSession(cancellation) { s in
            return try s.stat(path)
        }
    }
    public func download(path: String, to destination: URL, resumeOffset: Int64, cancellation: TransferCancellation,
                         progress: @escaping (NetworkProgress) -> Void) throws {
        try download(path: path, to: destination, resumeOffset: resumeOffset, maximumBytes: nil, cancellation: cancellation, progress: progress)
    }
    public func boundedDownload(path: String, to: URL, maximumBytes: Int64, cancellation: TransferCancellation,
                                progress: @escaping (NetworkProgress) -> Void) throws {
        guard (0...RemoteTransferLimits.maximumBytes).contains(maximumBytes) else { throw NetworkError.limitExceeded("Transfer download exceeds 1 TiB.") }
        try download(path: path, to: to, resumeOffset: 0, maximumBytes: maximumBytes, cancellation: cancellation, progress: progress)
    }
    public func searchDownload(path: String, to: URL, maximumBytes: Int64, cancellation: TransferCancellation,
                               progress: @escaping (NetworkProgress) -> Void) throws {
        guard (0...Int64(64 * 1024 * 1024)).contains(maximumBytes) else { throw NetworkError.limitExceeded("Search download exceeds 64 MiB.") }
        try download(path: path, to: to, resumeOffset: 0, maximumBytes: maximumBytes, cancellation: cancellation, progress: progress)
    }
    private func download(path: String, to destination: URL, resumeOffset: Int64, maximumBytes: Int64?,
                          cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        try validatePath(path)
        guard destination.isFileURL, !destination.path.contains("\0"), resumeOffset >= 0 else { throw SFTPError.invalidConfiguration }
        return try withSession(cancellation) { s in
            guard let entry = try s.stat(path), !entry.isDirectory, !entry.isSymbolicLink,
                  entry.size >= resumeOffset else { throw SFTPError.unsupported("Невозможно продолжить загрузку этого файла.") }
            if let maximumBytes, entry.size > maximumBytes { throw NetworkError.limitExceeded("Search file exceeds the expected size.") }
            let handle = try s.handle(type: 3, payload: SFTPPacket.string(path) + SFTPPacket.uint32(1) + SFTPPacket.uint32(0))
            let fd = open(destination.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | (resumeOffset == 0 ? O_TRUNC : 0), 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(fd) }
            var info = Darwin.stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == resumeOffset,
                  lseek(fd, off_t(resumeOffset), SEEK_SET) >= 0 else { throw SFTPError.unsupported("Локальная часть файла изменилась.") }
            var offset = resumeOffset
            progress(NetworkProgress(path: path, completedBytes: offset, totalBytes: entry.size))
            while offset < entry.size {
                var response = try s.request(5, SFTPPacket.string(handle) + SFTPPacket.uint64(UInt64(offset)) + SFTPPacket.uint32(UInt32(min(32768, entry.size - offset))))
                guard response.type == 103 else { throw SFTPError.malformedPacket }
                let bytes = try response.bytes()
                guard !bytes.isEmpty, bytes.count <= min(32768, entry.size - offset), response.remaining == 0 else { throw SFTPError.malformedPacket }
                try bytes.withUnsafeBytes { raw in
                    var written = 0
                    while written < raw.count {
                        if cancellation.isCancelled { throw SFTPError.cancelled }
                        let count = Darwin.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                        if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        guard count > 0 else { throw SFTPError.transport("Ошибка записи локального файла.") }
                        written += count
                    }
                }
                offset += Int64(bytes.count)
                progress(NetworkProgress(path: path, completedBytes: offset, totalBytes: entry.size))
            }
            guard let after = try s.stat(path), after.version == entry.version else { throw SFTPError.unsupported("Удалённый файл изменился во время загрузки.") }
            try s.close(handle)
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
    public func upload(from source: URL, to path: String, cancellation: TransferCancellation,
                       progress: @escaping (NetworkProgress) -> Void) throws {
        try validatePath(path)
        guard source.isFileURL, !source.path.contains("\0") else { throw SFTPError.invalidConfiguration }
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(input) }
        var before = Darwin.stat()
        guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw SFTPError.unsupported("Можно отправить только обычный файл.") }
        return try withSession(cancellation) { s in
            let parent = (path as NSString).deletingLastPathComponent
            let temp = (parent.isEmpty ? "" : parent + "/") + ".farmac-upload-" + UUID().uuidString
            var ownsTemp = false
            defer {
                if ownsTemp {
                    // Cleanup never reconnects or prompts. Cancellation/transport errors
                    // invalidate the session; a private temporary file may remain.
                    if !cancellation.isCancelled && s.canRequest {
                        _ = try? s.request(13, SFTPPacket.string(temp))
                    }
                }
            }
            let handle = try s.handle(type: 3, payload: SFTPPacket.string(temp) + SFTPPacket.uint32(2 | 8 | 32) + SFTPPacket.uint32(4) + SFTPPacket.uint32(0o600))
            ownsTemp = true
            var offset: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 32768)
            progress(NetworkProgress(path: path, completedBytes: 0, totalBytes: before.st_size))
            while true {
                if cancellation.isCancelled { throw SFTPError.cancelled }
                let count = Darwin.read(input, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if count == 0 { break }
                guard offset + Int64(count) <= before.st_size else { throw SFTPError.unsupported("Локальный файл изменился при отправке.") }
                _ = try s.request(6, SFTPPacket.string(handle) + SFTPPacket.uint64(UInt64(offset)) + SFTPPacket.string(Data(buffer.prefix(count))))
                offset += Int64(count)
                progress(NetworkProgress(path: path, completedBytes: offset, totalBytes: before.st_size))
            }
            var after = Darwin.stat()
            guard fstat(input, &after) == 0, offset == before.st_size, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw SFTPError.unsupported("Локальный файл изменился при отправке.")
            }
            try s.close(handle)
            try s.rename(from: temp, to: path, replace: true)
            ownsTemp = false
        }
    }
    public func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws {
        try validatePath(from); try validatePath(to)
        return try withSession(cancellation) { s in
            try s.rename(from: from, to: to, replace: replace)
        }
    }
    public func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws {
        try validatePath(path)
        return try withSession(cancellation) { s in
            _ = try s.request(isDirectory ? 15 : 13, SFTPPacket.string(path))
        }
    }
    public func makeDirectory(path: String, cancellation: TransferCancellation) throws {
        try validatePath(path)
        return try withSession(cancellation) { s in
            _ = try s.request(14, SFTPPacket.string(path) + SFTPPacket.uint32(4) + SFTPPacket.uint32(0o700))
        }
    }
}

// Encoding follows draft-ietf-secsh-filexfer-02 (SFTP v3), including opaque binary handles.
struct SFTPPacket {
    let type: UInt8
    private var data: Data
    private var cursor = 0
    var remaining: Int { data.count - cursor }
    init(type: UInt8, data: Data) { self.type = type; self.data = data }
    static func uint32(_ value: UInt32) -> Data { var x = value.bigEndian; return withUnsafeBytes(of: &x) { Data($0) } }
    static func uint64(_ value: UInt64) -> Data { var x = value.bigEndian; return withUnsafeBytes(of: &x) { Data($0) } }
    static func string(_ value: Data) -> Data { uint32(UInt32(value.count)) + value }
    static func string(_ value: String) -> Data { string(Data(value.utf8)) }
    mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPError.malformedPacket }
        var result: UInt32 = 0
        for byte in data[cursor..<cursor + 4] { result = (result << 8) | UInt32(byte) }
        cursor += 4; return result
    }
    mutating func uint64() throws -> UInt64 { (UInt64(try uint32()) << 32) | UInt64(try uint32()) }
    mutating func bytes() throws -> Data {
        let count = Int(try uint32())
        guard count <= remaining else { throw SFTPError.malformedPacket }
        defer { cursor += count }; return data.subdata(in: cursor..<cursor + count)
    }
    mutating func text() throws -> String {
        guard let text = String(data: try bytes(), encoding: .utf8), !text.contains("\0") else { throw SFTPError.malformedPacket }
        return text
    }
    mutating func attributes() throws -> SFTPAttributes {
        let flags = try uint32()
        guard flags & ~UInt32(0x8000000f) == 0 else { throw SFTPError.malformedPacket }
        var a = SFTPAttributes()
        if flags & 1 != 0 { let size = try uint64(); guard size <= UInt64(Int64.max) else { throw SFTPError.malformedPacket }; a.size = Int64(size) }
        if flags & 2 != 0 { _ = try uint32(); _ = try uint32() }
        if flags & 4 != 0 { a.permissions = try uint32() }
        if flags & 8 != 0 { _ = try uint32(); a.modified = try uint32() }
        if flags & 0x80000000 != 0 {
            let count = try uint32(); guard count <= 1024 else { throw SFTPError.malformedPacket }
            for _ in 0..<count { _ = try bytes(); _ = try bytes() }
        }
        return a
    }
}
struct SFTPAttributes {
    var size: Int64 = 0
    var permissions: UInt32 = 0
    var modified: UInt32?
    func entry(path: String) -> RemoteEntry {
        RemoteEntry(path: path, isDirectory: permissions & 0o170000 == 0o040000,
                    isSymbolicLink: permissions & 0o170000 == 0o120000, size: size,
                    modified: modified.map { Date(timeIntervalSince1970: Double($0)) },
                    version: "\(size):\(modified.map(String.init) ?? "?"):\(permissions)")
    }
}

private final class SFTPSession {
    let transport: SFTPProcess
    private var openHandles: Set<Data> = []
    private var synchronized = true
    var nextID: UInt32 = 0
    var extensions: Set<String> = []
    private let tunnels: SFTPTunnelChain?
    init(executable: String, arguments: [String], cancellation: TransferCancellation, timeout: Double, password: String? = nil, connectionCancellation: TransferCancellation? = nil,
         tunnels: SFTPTunnelChain? = nil, startupTimeout: Double? = nil,
         authenticationEndpoint: SFTPAuthenticationEndpoint? = nil, authenticationHandler: SFTPAuthenticationHandler? = nil) throws {
        self.tunnels = tunnels
        transport = try SFTPProcess(executable: executable, arguments: arguments, cancellation: cancellation, timeout: timeout,
                                    password: password, startupTimeout: startupTimeout, connectionCancellation: connectionCancellation, authenticationEndpoint: authenticationEndpoint, authenticationHandler: authenticationHandler)
        do {
            try send(type: 1, payload: SFTPPacket.uint32(3))
            var version = try receive()
            guard version.type == 2, try version.uint32() == 3 else { throw SFTPError.unsupportedVersion }
            while version.remaining > 0 { let name = try version.text(); _ = try version.bytes(); extensions.insert(name) }
            transport.finishAuthentication()
        } catch { stop(); throw error }
    }
    var isRunning: Bool { transport.isRunning && (tunnels?.isRunning ?? true) }
    var canRequest: Bool { isRunning && synchronized && !transport.operationCancelled }
    var isReusable: Bool { canRequest && openHandles.isEmpty }
    func bind(cancellation: TransferCancellation, connectionCancellation: TransferCancellation) {
        transport.bind(cancellation: cancellation, connectionCancellation: connectionCancellation)
        tunnels?.bind(cancellation: cancellation, connectionCancellation: connectionCancellation)
    }
    func unbind() { transport.unbind(); tunnels?.unbind() }
    func stop() { transport.stop(); tunnels?.stop() }
    deinit { stop() }
    func send(type: UInt8, payload: Data) throws { try transport.write(SFTPPacket.uint32(UInt32(payload.count + 1)) + Data([type]) + payload) }
    func receive() throws -> SFTPPacket {
        var header = SFTPPacket(type: 0, data: try transport.read(4))
        let length = Int(try header.uint32())
        guard length >= 1, length <= 4 * 1024 * 1024 else { throw SFTPError.malformedPacket }
        let data = try transport.read(length)
        return SFTPPacket(type: data[0], data: Data(data.dropFirst()))
    }
    func request(_ type: UInt8, _ payload: Data, allowEOF: Bool = false) throws -> SFTPPacket {
        synchronized = false
        transport.beginRequest(); nextID &+= 1
        try send(type: type, payload: SFTPPacket.uint32(nextID) + payload)
        var response = try receive()
        guard try response.uint32() == nextID else { throw SFTPError.malformedPacket }
        if response.type == 101 {
            var status = response
            let code = try status.uint32(); let message = try status.text(); _ = try status.bytes()
            guard status.remaining == 0 else { throw SFTPError.malformedPacket }
            synchronized = true
            guard code == 0 || (allowEOF && code == 1) else { throw SFTPError.status(code, message) }
        }
        if [4, 6, 13, 14, 15, 18, 200].contains(type), response.type != 101 { throw SFTPError.malformedPacket }
        synchronized = true
        return response
    }
    func handle(type: UInt8, payload: Data) throws -> Data {
        var response = try request(type, payload)
        guard response.type == 102 else { throw SFTPError.malformedPacket }
        let handle = try response.bytes(); guard !handle.isEmpty, response.remaining == 0 else { throw SFTPError.malformedPacket }
        openHandles.insert(handle)
        return handle
    }
    func close(_ handle: Data) throws { _ = try request(4, SFTPPacket.string(handle)); openHandles.remove(handle) }
    func stat(_ path: String) throws -> RemoteEntry? {
        do {
            var response = try request(7, SFTPPacket.string(path)) // LSTAT: do not silently follow links.
            guard response.type == 105 else { throw SFTPError.malformedPacket }
            let attrs = try response.attributes(); guard response.remaining == 0 else { throw SFTPError.malformedPacket }
            return attrs.entry(path: path)
        } catch SFTPError.status(2, _) { return nil }
    }
    func rename(from: String, to: String, replace: Bool) throws {
        if replace {
            guard extensions.contains("posix-rename@openssh.com") else {
                if try stat(to) != nil { throw SFTPError.unsupported("Сервер не поддерживает безопасную замену файла.") }
                _ = try request(18, SFTPPacket.string(from) + SFTPPacket.string(to)); return
            }
            _ = try request(200, SFTPPacket.string("posix-rename@openssh.com") + SFTPPacket.string(from) + SFTPPacket.string(to))
        } else { _ = try request(18, SFTPPacket.string(from) + SFTPPacket.string(to)) }
    }
}

/// Nonblocking pipes keep cancellation and request deadlines effective during authentication and I/O.
final class SFTPProcess {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var cancellation: TransferCancellation?
    private var connectionCancellation: TransferCancellation?
    private let timeout: Double
    private var deadline: TimeInterval
    private var diagnostics = Data()
    private var stopped = false
    private var started = false
    private var passwordPrompt: SFTPPasswordPrompt?
    private var interactivePrompt: SFTPInteractivePrompt?
    private let passwordAuthentication: Bool
    private var rawErrorText: String {
        drainErrors()
        return String(decoding: diagnostics, as: UTF8.self)
    }
    var errorText: String {
        SFTPProvider.transportDiagnostics(rawErrorText, passwordAuthentication: passwordAuthentication)
    }
    init(executable: String, arguments: [String], cancellation: TransferCancellation, timeout: Double, password: String? = nil, startupTimeout: Double? = nil, connectionCancellation: TransferCancellation? = nil,
         authenticationEndpoint: SFTPAuthenticationEndpoint? = nil, authenticationHandler: SFTPAuthenticationHandler? = nil) throws {
        self.cancellation = cancellation; self.connectionCancellation = connectionCancellation; self.timeout = timeout; passwordAuthentication = password != nil || authenticationEndpoint != nil
        deadline = ProcessInfo.processInfo.systemUptime + (startupTimeout ?? timeout)
        if cancellation.isCancelled || connectionCancellation?.isCancelled == true { throw SFTPError.cancelled }
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment = SFTPPasswordPrompt.sanitizedEnvironment(environment)
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        if let endpoint = authenticationEndpoint {
            let prompt = try SFTPInteractivePrompt(endpoint: endpoint, handler: authenticationHandler)
            interactivePrompt = prompt
            environment.merge(prompt.environment) { _, new in new }
        } else if let password {
            let prompt = try SFTPPasswordPrompt(password: password)
            passwordPrompt = prompt
            environment.merge(prompt.environment) { _, new in new }
        }
        process.environment = environment
        do { try process.run(); started = true } catch { passwordPrompt?.stop(); interactivePrompt?.stop(); throw error }
        // Parent closes child ends so EOF is observable.
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }
    }
    deinit { stop() }
    func finishAuthentication() { interactivePrompt?.stop(); interactivePrompt = nil; passwordPrompt?.stop(); passwordPrompt = nil }
    var isRunning: Bool { started && !stopped && process.isRunning }
    var operationCancelled: Bool { cancellation?.isCancelled == true || connectionCancellation?.isCancelled == true }
    func bind(cancellation: TransferCancellation, connectionCancellation: TransferCancellation) {
        self.cancellation = cancellation; self.connectionCancellation = connectionCancellation
        beginRequest()
    }
    func unbind() { cancellation = nil; connectionCancellation = nil }
    func beginRequest() { deadline = ProcessInfo.processInfo.systemUptime + timeout }
    func stop() {
        guard !stopped else { return }; stopped = true
        // Stop SSH before releasing askpass. OpenSSH turns an askpass failure into
        // an empty answer, which must not be sent after cancellation or timeout.
        if started, process.isRunning {
            process.terminate()
            let limit = ProcessInfo.processInfo.systemUptime + 0.15
            while process.isRunning && ProcessInfo.processInfo.systemUptime < limit { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        finishAuthentication()
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        if started {
            // A reusable session can be launched and stopped on different
            // workers. Foundation's waitUntilExit can wait forever in its run
            // loop even after the child has already been reaped. Foundation
            // handles child reaping; observe OS disappearance with a bound,
            // rather than waiting for delivery of its task notification.
            let limit = ProcessInfo.processInfo.systemUptime + 0.35
            while kill(process.processIdentifier, 0) == 0 && ProcessInfo.processInfo.systemUptime < limit { usleep(5_000) }
        }
    }
    private func check() throws {
        do {
            if cancellation?.isCancelled == true || connectionCancellation?.isCancelled == true { throw SFTPError.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw SFTPError.timedOut }
            try interactivePrompt?.poll()
        } catch { stop(); throw error }
    }
    private func drainErrors() {
        guard !stopped else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = Darwin.read(errors.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count <= 0 { break }
            if diagnostics.count < 16_384 { diagnostics.append(contentsOf: buffer.prefix(min(count, 16_384 - diagnostics.count))) }
        }
    }
    private func wait(_ fd: Int32, events: Int16) throws {
        while true {
            try check(); drainErrors()
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&pfd, 1, 50)
            if result < 0 { if errno == EINTR { continue }; throw SFTPError.transport(errorText) }
            if result > 0 { return }
        }
    }
    /// OpenSSH creates this private control socket only after authentication and
    /// successful local-forward setup (ExitOnForwardFailure=yes).
    func waitForTunnel(controlURL: URL) throws {
        while true {
            try check(); drainErrors()
            guard process.isRunning else { throw transportError() }
            var info = Darwin.stat()
            if lstat(controlURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK { finishAuthentication(); return }
            usleep(10_000)
        }
    }
    private func transportError() -> SFTPError {
        let text = rawErrorText
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || text.contains("Offending ") { return .changedHostKey }
        if text.contains("Host key verification failed") || text.contains("No ") && text.contains("host key is known") { return .unknownHostKey }
        if text.contains("Permission denied") { return .authenticationFailed }
        let safeText = errorText
        return .transport(safeText.isEmpty ? "Соединение закрыто сервером." : safeText)
    }
    func read(_ count: Int) throws -> Data {
        var result = Data(); var bytes = [UInt8](repeating: 0, count: min(count, 32768))
        while result.count < count {
            try wait(output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN))
            let n = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, min(bytes.count, count - result.count))
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw SFTPError.transport(errorText) }
            guard n > 0 else { throw transportError() }
            result.append(contentsOf: bytes.prefix(n))
        }
        return result
    }
    func readToEnd(limit: Int) throws -> Data {
        var result = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN))
            let n = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw SFTPError.transport(errorText) }
            if n == 0 { break }
            guard result.count + n <= limit else { throw SFTPError.malformedPacket }
            result.append(contentsOf: bytes.prefix(n))
        }
        return result
    }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try wait(input.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT))
                let n = Darwin.write(input.fileHandleForWriting.fileDescriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw SFTPError.transport(errorText) }
                guard n > 0 else { throw SFTPError.transport(errorText) }; offset += n
            }
        }
    }
}
