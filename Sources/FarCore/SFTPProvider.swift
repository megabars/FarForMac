import Foundation
import Darwin
import CryptoKit

public enum SFTPError: LocalizedError, Equatable {
    case invalidConfiguration, malformedPacket, unsupportedVersion, cancelled, timedOut
    case transport(String), status(UInt32, String), unsupported(String)
    case unknownHostKey, changedHostKey, authenticationFailed
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Проверьте адрес, порт и имя пользователя SFTP."
        case .malformedPacket: return "Сервер вернул некорректный пакет SFTP."
        case .unsupportedVersion: return "Сервер не поддерживает SFTP версии 3."
        case .cancelled: return "Операция отменена."
        case .timedOut: return "Время ожидания SFTP истекло."
        case .unknownHostKey: return "Ключ сервера ещё не подтверждён. Сравните отпечаток с владельцем сервера."
        case .changedHostKey: return "Ключ сервера изменился. Проверьте замену ключа у владельца сервера."
        case .authenticationFailed: return "Сервер отклонил SSH-ключ. Добавьте ключ в ssh-agent или выберите закрытый ключ."
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
    public func probe(connection: NetworkConnection, cancellation: TransferCancellation) throws -> [SFTPHostKey] {
        try SFTPProvider.validate(connection)
        let transport = try SFTPProcess(executable: "/usr/bin/ssh-keyscan",
            arguments: ["-T", String(max(1, Int(connection.timeoutSeconds))), "-p", String(connection.port), "-t", "ed25519,ecdsa,rsa", connection.host],
            cancellation: cancellation, timeout: connection.timeoutSeconds)
        defer { transport.stop() }
        let data = try transport.readToEnd(limit: 256 * 1024)
        let keys = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> SFTPHostKey? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, !line.hasPrefix("#"), Data(base64Encoded: String(fields[2])) != nil else { return nil }
            return SFTPHostKey(host: connection.host, port: connection.port, keyType: String(fields[1]), publicKey: String(fields[2]))
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
/// Authentication uses ssh-agent / identity files and macOS Keychain key passphrases.
public final class SFTPProvider: RemoteProvider {
    public let connection: NetworkConnection
    public let knownHostsURL: URL
    private let testCommand: (String, [String])?
    public init(connection: NetworkConnection, knownHostsURL: URL = SFTPHostKeyStore.defaultURL) {
        self.connection = connection; self.knownHostsURL = knownHostsURL; testCommand = nil
    }
    // Exercises the same binary engine against the shipped local sftp-server in tests.
    init(connection: NetworkConnection, subsystemExecutable: String, arguments: [String] = []) {
        self.connection = connection; knownHostsURL = SFTPHostKeyStore.defaultURL
        testCommand = (subsystemExecutable, arguments)
    }
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || [45,46,58,95].contains($0)
        }
    }
    static func validate(_ c: NetworkConnection) throws {
        guard validHost(c.host), (1...65535).contains(c.port), !c.username.isEmpty,
              !c.username.contains("\0"), !c.username.contains(where: { $0.isNewline }), c.timeoutSeconds.isFinite,
              c.timeoutSeconds > 0, c.timeoutSeconds <= 3600 else { throw SFTPError.invalidConfiguration }
    }
    static func sshArguments(connection c: NetworkConnection, knownHostsURL: URL) throws -> [String] {
        try validate(c)
        // -F /dev/null also ignores system configuration, preventing ProxyCommand / LocalCommand hooks.
        var args = ["-F", "/dev/null", "-T", "-a", "-x", "-s", "-p", String(c.port), "-l", c.username,
                    "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "UserKnownHostsFile=\"\(knownHostsURL.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"",
                    "-o", "GlobalKnownHostsFile=/dev/null", "-o", "HostKeyAlias=[\(c.host)]:\(c.port)",
                    "-o", "UpdateHostKeys=no", "-o", "VerifyHostKeyDNS=no", "-o", "CheckHostIP=no",
                    "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
                    "-o", "PreferredAuthentications=publickey", "-o", "UseKeychain=yes",
                    "-o", "ConnectTimeout=\(max(1, Int(c.timeoutSeconds)))", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2"]
        if let identity = c.privateKeyPath, !identity.isEmpty { args += ["-i", identity, "-o", "IdentitiesOnly=yes"] }
        args += ["--", c.host, "sftp"]
        return args
    }
    private func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 16_384, !path.contains("\0") else {
            throw NetworkError.invalidPath(path)
        }
    }
    private func session(_ cancellation: TransferCancellation, timeout: Double? = nil) throws -> SFTPSession {
        try Self.validate(connection)
        let command = try testCommand ?? ("/usr/bin/ssh", Self.sshArguments(connection: connection, knownHostsURL: knownHostsURL))
        return try SFTPSession(executable: command.0, arguments: command.1, cancellation: cancellation,
                               timeout: timeout ?? connection.timeoutSeconds)
    }
    public func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        try validatePath(path)
        let s = try session(cancellation); defer { s.stop() }
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
    public func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? {
        try validatePath(path)
        let s = try session(cancellation); defer { s.stop() }
        return try s.stat(path)
    }
    public func download(path: String, to destination: URL, resumeOffset: Int64, cancellation: TransferCancellation,
                         progress: @escaping (NetworkProgress) -> Void) throws {
        try validatePath(path)
        guard destination.isFileURL, !destination.path.contains("\0"), resumeOffset >= 0 else { throw SFTPError.invalidConfiguration }
        let s = try session(cancellation); defer { s.stop() }
        guard let entry = try s.stat(path), !entry.isDirectory, !entry.isSymbolicLink,
              entry.size >= resumeOffset else { throw SFTPError.unsupported("Невозможно продолжить загрузку этого файла.") }
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
    public func upload(from source: URL, to path: String, cancellation: TransferCancellation,
                       progress: @escaping (NetworkProgress) -> Void) throws {
        try validatePath(path)
        guard source.isFileURL, !source.path.contains("\0") else { throw SFTPError.invalidConfiguration }
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(input) }
        var before = Darwin.stat()
        guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw SFTPError.unsupported("Можно отправить только обычный файл.") }
        let s = try session(cancellation); defer { s.stop() }
        let parent = (path as NSString).deletingLastPathComponent
        let temp = (parent.isEmpty ? "" : parent + "/") + ".farmac-upload-" + UUID().uuidString
        var ownsTemp = false
        defer {
            if ownsTemp {
                // Cancellation can leave an outstanding response, so cleanup uses a fresh connection.
                if let cleanup = try? session(TransferCancellation(), timeout: 2) {
                    defer { cleanup.stop() }; _ = try? cleanup.request(13, SFTPPacket.string(temp))
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
    public func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws {
        try validatePath(from); try validatePath(to)
        let s = try session(cancellation); defer { s.stop() }; try s.rename(from: from, to: to, replace: replace)
    }
    public func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws {
        try validatePath(path)
        let s = try session(cancellation); defer { s.stop() }; _ = try s.request(isDirectory ? 15 : 13, SFTPPacket.string(path))
    }
    public func makeDirectory(path: String, cancellation: TransferCancellation) throws {
        try validatePath(path)
        let s = try session(cancellation); defer { s.stop() }
        _ = try s.request(14, SFTPPacket.string(path) + SFTPPacket.uint32(4) + SFTPPacket.uint32(0o700))
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
    var nextID: UInt32 = 0
    var extensions: Set<String> = []
    init(executable: String, arguments: [String], cancellation: TransferCancellation, timeout: Double) throws {
        transport = try SFTPProcess(executable: executable, arguments: arguments, cancellation: cancellation, timeout: timeout)
        do {
            try send(type: 1, payload: SFTPPacket.uint32(3))
            var version = try receive()
            guard version.type == 2, try version.uint32() == 3 else { throw SFTPError.unsupportedVersion }
            while version.remaining > 0 { let name = try version.text(); _ = try version.bytes(); extensions.insert(name) }
        } catch { transport.stop(); throw error }
    }
    func stop() { transport.stop() }
    func send(type: UInt8, payload: Data) throws { try transport.write(SFTPPacket.uint32(UInt32(payload.count + 1)) + Data([type]) + payload) }
    func receive() throws -> SFTPPacket {
        var header = SFTPPacket(type: 0, data: try transport.read(4))
        let length = Int(try header.uint32())
        guard length >= 1, length <= 4 * 1024 * 1024 else { throw SFTPError.malformedPacket }
        let data = try transport.read(length)
        return SFTPPacket(type: data[0], data: Data(data.dropFirst()))
    }
    func request(_ type: UInt8, _ payload: Data, allowEOF: Bool = false) throws -> SFTPPacket {
        transport.beginRequest(); nextID &+= 1
        try send(type: type, payload: SFTPPacket.uint32(nextID) + payload)
        var response = try receive()
        guard try response.uint32() == nextID else { throw SFTPError.malformedPacket }
        if response.type == 101 {
            var status = response
            let code = try status.uint32(); let message = try status.text(); _ = try status.bytes()
            guard status.remaining == 0 else { throw SFTPError.malformedPacket }
            guard code == 0 || (allowEOF && code == 1) else { throw SFTPError.status(code, message) }
        }
        if [4, 6, 13, 14, 15, 18, 200].contains(type), response.type != 101 { throw SFTPError.malformedPacket }
        return response
    }
    func handle(type: UInt8, payload: Data) throws -> Data {
        var response = try request(type, payload)
        guard response.type == 102 else { throw SFTPError.malformedPacket }
        let handle = try response.bytes(); guard !handle.isEmpty, response.remaining == 0 else { throw SFTPError.malformedPacket }
        return handle
    }
    func close(_ handle: Data) throws { _ = try request(4, SFTPPacket.string(handle)) }
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
private final class SFTPProcess {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let cancellation: TransferCancellation
    private let timeout: Double
    private var deadline: TimeInterval
    private var diagnostics = Data()
    private var stopped = false
    private var started = false
    var errorText: String { drainErrors(); return String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    init(executable: String, arguments: [String], cancellation: TransferCancellation, timeout: Double) throws {
        self.cancellation = cancellation; self.timeout = timeout
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        if cancellation.isCancelled { throw SFTPError.cancelled }
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["SSH_ASKPASS_REQUIRE"] = "never"; environment.removeValue(forKey: "SSH_ASKPASS")
        process.environment = environment
        try process.run(); started = true
        // Parent closes child ends so EOF is observable.
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }
    }
    deinit { stop() }
    func beginRequest() { deadline = ProcessInfo.processInfo.systemUptime + timeout }
    func stop() {
        guard !stopped else { return }; stopped = true
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        guard started else { return }
        if process.isRunning {
            process.terminate()
            let limit = ProcessInfo.processInfo.systemUptime + 0.15
            while process.isRunning && ProcessInfo.processInfo.systemUptime < limit { usleep(5_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }
    private func check() throws {
        if cancellation.isCancelled { throw SFTPError.cancelled }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw SFTPError.timedOut }
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
    private func transportError() -> SFTPError {
        let text = errorText
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || text.contains("Offending ") { return .changedHostKey }
        if text.contains("Host key verification failed") || text.contains("No ") && text.contains("host key is known") { return .unknownHostKey }
        if text.contains("Permission denied") { return .authenticationFailed }
        return .transport(text.isEmpty ? "Соединение закрыто сервером." : text)
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
