import Foundation

public enum NetworkProtocol: String, Codable, CaseIterable, Sendable {
    case sftp, ftp, ftps, webdav, webdavs
    public var defaultPort: Int { switch self { case .sftp: return 22; case .ftp, .ftps: return 21; case .webdav: return 80; case .webdavs: return 443 } }
    public var title: String { switch self { case .sftp: return "SFTP (SSH)"; case .ftp: return "FTP"; case .ftps: return "FTPS (явный TLS)"; case .webdav: return "WebDAV (HTTP)"; case .webdavs: return "WebDAV (HTTPS)" } }
    public var isCleartext: Bool { self == .ftp || self == .webdav }
}

/// Connection metadata only. Passwords and key passphrases never belong here.
public struct NetworkConnection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: NetworkProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var rootPath: String
    public var privateKeyPath: String?
    public var timeoutSeconds: Double
    public init(id: UUID = UUID(), name: String = "", kind: NetworkProtocol, host: String, port: Int? = nil,
                username: String = "", rootPath: String = "/", privateKeyPath: String? = nil, timeoutSeconds: Double = 30) {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.port = port ?? kind.defaultPort
        self.username = username; self.rootPath = rootPath; self.privateKeyPath = privateKeyPath; self.timeoutSeconds = timeoutSeconds
    }
    public func validate() throws {
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) }),
              (1...65535).contains(port), timeoutSeconds.isFinite, (1...600).contains(timeoutSeconds),
              !username.contains(where: { $0.isNewline || $0 == "\0" }), username.utf8.count <= 256 else {
            throw NetworkError.invalidConnection("Проверьте адрес сервера, порт, имя пользователя и таймаут (1–600 с).")
        }
        _ = try RemotePath.validate(rootPath)
        if let key = privateKeyPath, !key.isEmpty {
            guard key.hasPrefix("/"), !key.contains("\0"), !key.contains("\n"), !key.contains("\r") else { throw NetworkError.invalidConnection("Укажите абсолютный путь к закрытому ключу.") }
        }
    }
    public var displayName: String { name.isEmpty ? "\(kind.rawValue)://\(host):\(port)" : name }
}

public struct RemoteEntry: Equatable, Sendable, Identifiable {
    public let path: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let modified: Date?
    /// ETag or protocol-specific change token, not assumed to be a content hash.
    public let version: String?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public init(path: String, isDirectory: Bool, isSymbolicLink: Bool = false, size: Int64, modified: Date? = nil, version: String? = nil) {
        self.path = path; self.isDirectory = isDirectory; self.isSymbolicLink = isSymbolicLink; self.size = size; self.modified = modified; self.version = version
    }
}
public struct NetworkProgress: Sendable {
    public let path: String
    public let completedBytes: Int64
    public let totalBytes: Int64
    public init(path: String, completedBytes: Int64, totalBytes: Int64) { self.path = path; self.completedBytes = completedBytes; self.totalBytes = totalBytes }
}
public protocol RemoteProvider: AnyObject {
    var connection: NetworkConnection { get }
    func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry]
    func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry?
    func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws
    func upload(from: URL, to: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws
    func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws
    func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws
    func makeDirectory(path: String, cancellation: TransferCancellation) throws
}
public enum NetworkError: LocalizedError, Equatable {
    case invalidConnection(String), invalidPath(String), unsupported(String), cancelled, timedOut
    case connectionFailed(String), conflict(String), changedSource, notFound(String), limitExceeded(String), io(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConnection(let s), .unsupported(let s), .connectionFailed(let s), .limitExceeded(let s), .io(let s): return s
        case .invalidPath(let s): return "Недопустимый удалённый путь: \(s)"
        case .cancelled: return "Сетевая операция отменена."
        case .timedOut: return "Сервер не ответил в установленное время."
        case .conflict(let s): return "Объект уже существует или изменён: \(s)"
        case .changedSource: return "Исходный объект изменился. Обновите список и повторите операцию."
        case .notFound(let s): return "Объект не найден: \(s)"
        }
    }
}
public enum RemotePath {
    @discardableResult public static func validate(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path.utf8.count <= 16_384,
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), !path.contains("\\"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              !path.contains("//") else { throw NetworkError.invalidPath(path) }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
    public static func child(_ name: String, of parent: String) throws -> String {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw NetworkError.invalidPath(name) }
        let base = try validate(parent)
        return try validate((base == "/" ? "" : base) + "/" + name)
    }
    public static func parent(_ path: String) -> String {
        let value = (path as NSString).deletingLastPathComponent
        return value.isEmpty ? "/" : value
    }
}

public enum NetworkProfileStore {
    public static var defaultURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FarForMac/Connections.json") }
    public static func load(from url: URL = defaultURL) throws -> [NetworkConnection] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 1024 * 1024 else { throw NetworkError.limitExceeded("Список подключений превышает 1 МиБ.") }
        let profiles = try JSONDecoder().decode([NetworkConnection].self, from: data)
        guard profiles.count <= 100, Set(profiles.map(\.id)).count == profiles.count else { throw NetworkError.invalidConnection("Некорректный список подключений.") }
        try profiles.forEach { try $0.validate() }; return profiles
    }
    public static func save(_ profiles: [NetworkConnection], to url: URL = defaultURL) throws {
        guard profiles.count <= 100, Set(profiles.map(\.id)).count == profiles.count else { throw NetworkError.limitExceeded("Не более 100 подключений с уникальными идентификаторами.") }
        try profiles.forEach { try $0.validate() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
