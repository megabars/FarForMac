import Darwin
import Foundation

public struct LocalSMBServer: Hashable, Sendable {
    public let host: String
    public let port: Int?

    public init(address: String) throws {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("\\\\") { address = String(address.dropFirst(2)) }
        if address.hasPrefix("//") { address = String(address.dropFirst(2)) }
        if !address.hasPrefix("["), address.filter({ $0 == ":" }).count > 1, !address.contains("/") {
            address = "[\(address)]"
        }
        let url = address.lowercased().hasPrefix("smb://") ? address : "smb://" + address
        guard let components = URLComponents(string: url), components.scheme?.lowercased() == "smb",
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host, !host.isEmpty, host.utf8.count <= 255,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !host.contains(where: { "/\\@?#".contains($0) }),
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              components.url != nil else { throw LocalSMBError.invalidServer }
        self.host = host
        self.port = components.port
    }

    public init(host: String, port: Int) throws {
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        try self.init(address: "\(authority):\(port)")
    }

    private var components: URLComponents {
        var result = URLComponents()
        result.scheme = "smb"
        result.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        result.port = port
        return result
    }

    public var displayAddress: String { components.url?.absoluteString.dropFirst(6).description ?? host }

    func url(share: String? = nil, account: LocalSMBAccount? = nil) throws -> URL {
        var result = components
        if let share {
            guard Self.validShareName(share) else { throw LocalSMBError.invalidShare }
            result.path = "/" + share
        }
        result.percentEncodedUser = account?.encodedUser
        guard let url = result.url else { throw LocalSMBError.invalidServer }
        return url
    }

    static func validShareName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 240
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    func matches(host other: String, port otherPort: Int?) -> Bool {
        func canonical(_ host: String) -> String {
            (host.hasSuffix(".") ? String(host.dropLast()) : host).lowercased()
        }
        return canonical(host) == canonical(other) && (port ?? 445) == (otherPort ?? 445)
    }
}

public struct LocalSMBAccount: Sendable {
    let user: String
    let encodedUser: String
    let password: String

    public init(user: String, password: String) throws {
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = user.split(separator: "\\", omittingEmptySubsequences: false)
        guard (1...2).contains(components.count), components.allSatisfy({ !$0.isEmpty }),
              components.last.map({ $0.utf8.count <= 128 }) ?? false,
              components.count == 1 || components[0].utf8.count <= 15,
              !user.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              password.utf8.count <= 128, !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw LocalSMBError.invalidAccount }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = components.compactMap { String($0).addingPercentEncoding(withAllowedCharacters: unreserved) }
        guard encoded.count == components.count else { throw LocalSMBError.invalidAccount }
        encodedUser = encoded.joined(separator: ";")
        self.user = user
        self.password = password
    }
}

public enum LocalSMBError: LocalizedError, Equatable {
    case invalidServer, invalidShare, invalidAccount, cannotResolve, listingFailed, listingFormat, timedOut
    case mountFailed(Int32), mountMissing

    public var errorDescription: String? {
        switch self {
        case .invalidServer: return "Укажите имя или IP-адрес SMB-сервера без пути и учётных данных."
        case .invalidShare: return "Недопустимое имя общей папки SMB."
        case .invalidAccount: return "Проверьте имя пользователя и пароль. Для домена используйте формат ДОМЕН\\пользователь."
        case .cannotResolve: return "Не удалось определить адрес SMB-сервера."
        case .listingFailed: return "Не удалось получить список общих папок. Проверьте доступ к серверу или нажмите F4 для входа."
        case .listingFormat: return "macOS вернула список общих папок в неподдерживаемом формате."
        case .timedOut: return "Истекло время ожидания ответа SMB."
        case .mountFailed(let code): return "macOS не смогла подключить общую папку SMB (код \(code))."
        case .mountMissing: return "macOS не вернула путь подключённого тома SMB."
        }
    }
}

public struct LocalSMBShare: Hashable, Sendable {
    public let name: String
}

public struct LocalSMBMount: Equatable, Sendable {
    public let url: URL
    private let source: String
    private let device: Int32
    private let mountID: Int32

    /// Uses the kernel's cached mount table without probing remote servers.
    public static func matching(server: LocalSMBServer, share: LocalSMBShare) -> [Self] {
        matching(server: server, shares: [share])[share] ?? []
    }

    public static func matching(server: LocalSMBServer, shares: [LocalSMBShare]) -> [LocalSMBShare: [Self]] {
        var matches: [LocalSMBShare: [Self]] = [:]
        for mount in snapshot() {
            guard let target = URLComponents(string: "smb:" + mount.source), let host = target.host,
                  server.matches(host: host, port: target.port),
                  let share = shares.first(where: { target.path.caseInsensitiveCompare("/" + $0.name) == .orderedSame })
            else { continue }
            matches[share, default: []].append(mount)
        }
        return matches
    }

    public func disconnect() throws {
        guard Self.snapshot().contains(self) else { throw LocalSMBError.mountMissing }
        let code = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return EINVAL }
            return Darwin.unmount(path, 0) == 0 ? 0 : errno
        }
        if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }

    private static func snapshot() -> [Self] {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&table, MNT_NOWAIT)
        defer { free(table) }
        guard let table, count > 0 else { return [] }
        return UnsafeBufferPointer(start: table, count: Int(count)).compactMap { volume in
            func field<T>(_ value: T) -> String {
                withUnsafeBytes(of: value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            guard field(volume.f_fstypename) == "smbfs" else { return nil }
            let path = field(volume.f_mntonname)
            guard path.hasPrefix("/") else { return nil }
            let identifier = volume.f_fsid.val
            return Self(url: URL(fileURLWithPath: path, isDirectory: true), source: field(volume.f_mntfromname),
                        device: identifier.0, mountID: identifier.1)
        }
    }
}
