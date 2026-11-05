import Foundation

public enum SavedNetworkProfiles {
    public static func validateGroup(_ group: [String]) throws {
        guard group.count <= 32, group.allSatisfy(validComponent) else {
            throw NetworkError.invalidPath(group.joined(separator: "/"))
        }
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        value != "." && value != ".." && value.utf8.count <= 255 &&
        !value.contains("/") && !value.contains("\\") &&
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    public static func assigningPath(_ path: String, to connection: NetworkConnection) throws -> NetworkConnection {
        let parts = path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/")
        guard let name = parts.last, validComponent(name) else { throw NetworkError.invalidPath(path) }
        var updated = connection
        updated.profileGroup = Array(parts.dropLast())
        try validateGroup(updated.profileGroup)
        updated.name = name
        return updated
    }

    public static func path(for connection: NetworkConnection) -> String {
        let leaf = connection.name.isEmpty ? connection.host : connection.name
        return (connection.profileGroup + [leaf]).joined(separator: "/")
    }

    public static func matches(_ group: [String], prefix: [String]) -> Bool {
        group.count >= prefix.count && zip(group, prefix).allSatisfy { $0.0.caseInsensitiveCompare($0.1) == .orderedSame }
    }

    public static func sameName(_ lhs: NetworkConnection, _ rhs: NetworkConnection) -> Bool {
        lhs.profileGroup.count == rhs.profileGroup.count && matches(lhs.profileGroup, prefix: rhs.profileGroup) &&
        (lhs.name.isEmpty ? lhs.host : lhs.name).caseInsensitiveCompare(rhs.name.isEmpty ? rhs.host : rhs.name) == .orderedSame
    }

    public static func upsert(_ profile: NetworkConnection, in profiles: inout [NetworkConnection]) throws {
        let index = profiles.firstIndex { $0.id == profile.id }
        let changesName = index.map { !sameName(profiles[$0], profile) } ?? true
        if changesName, profiles.contains(where: { $0.id != profile.id && sameName($0, profile) }) {
            throw NetworkError.conflict(path(for: profile))
        }
        if let index { profiles[index] = profile } else { profiles.append(profile) }
    }
}

/// The NetBox XML exchange format for settings with equivalents in FarForMac.
public enum NetBoxSessionFile {
    public static func read(from url: URL) throws -> [NetworkConnection] {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw NetworkError.invalidConnection("Выберите обычный файл сессии NetBox.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> [NetworkConnection] {
        guard data.count <= 1024 * 1024 else { throw NetworkError.limitExceeded("Файл NetBox превышает 1 МиБ.") }
        // NetBox writes UTF-8. Restrict the accepted XML before parsing to prevent DTD/entity expansion.
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0"), !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else {
            throw NetworkError.invalidConnection("Некорректный XML-файл NetBox.")
        }
        let document = try XMLDocument(data: Data(text.utf8), options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), root.name == "NetBox",
              let container = root.elements(forName: "Sessions").first else {
            throw NetworkError.invalidConnection("Файл не содержит сохранённых сессий NetBox.")
        }
        let sessions = container.elements(forName: "Session")
        guard (1...100).contains(sessions.count) else {
            throw NetworkError.limitExceeded("Файл должен содержать от 1 до 100 сессий NetBox.")
        }
        return try sessions.map(decodeSession)
    }

    private static func decodeSession(_ session: XMLElement) throws -> NetworkConnection {
        func raw(_ key: String) -> String? { session.elements(forName: key).first?.stringValue }
        func value(_ key: String) throws -> String { try unescape(raw(key) ?? "") }
        guard let encodedName = session.attribute(forName: "name")?.stringValue else {
            throw NetworkError.invalidConnection("Сессия NetBox не содержит имени.")
        }
        let proxy = try value("ProxyMethod").lowercased()
        guard ["", "none", "0"].contains(proxy), ["", "0"].contains(raw("Tunnel") ?? ""),
              try value("TlsCertificateFile").isEmpty, try value("DetachedCertificate").isEmpty,
              try value("LogicalHostName").isEmpty, try value("SourceAddress").isEmpty else {
            throw NetworkError.unsupported("Сессия NetBox использует параметры маршрута или сертификата, которых нет в этом формате обмена FarForMac.")
        }
        let protocolName = try value("FSProtocol")
        let encryption = raw("Ftps") ?? "0"
        let kind: NetworkProtocol
        switch (protocolName, encryption) {
        case ("", "0"), ("SFTP", "0"), ("SFTP (SCP)", "0"): kind = .sftp
        case ("FTP", "0"): kind = .ftp
        case ("FTP", "2"), ("FTP", "3"): kind = .ftps
        case ("WebDAV", "0"): kind = .webdav
        case ("WebDAV", "1"), ("WebDAV", "2"), ("WebDAV", "3"): kind = .webdavs
        default: throw NetworkError.unsupported("Протокол или режим шифрования сессии NetBox не поддерживается.")
        }
        let key = try value("PublicKeyFile")
        // PuTTY .ppk and Windows paths cannot be used by the native SSH client.
        guard key.isEmpty || (key.hasPrefix("/") && !key.lowercased().hasSuffix(".ppk")) else {
            throw NetworkError.unsupported("Сессия NetBox ссылается на закрытый ключ Windows или PuTTY.")
        }
        let port = raw("PortNumber").flatMap(Int.init)
        let timeout = raw("Timeout").flatMap(Double.init)
        guard port != nil || raw("PortNumber") == nil, timeout != nil || raw("Timeout") == nil else {
            throw NetworkError.invalidConnection("В сессии NetBox указан некорректный порт или таймаут.")
        }
        let authMode: SFTPAuthenticationMode
        let containsPassword = !(raw("Password") ?? "").isEmpty || !(raw("PasswordPlain") ?? "").isEmpty
        if raw("AuthKI") == "1", raw("AuthKIPassword") == "0" { authMode = .interactive }
        else if key.isEmpty && containsPassword || raw("TryAgent") == "0" && (key.isEmpty || raw("AuthKIPassword") == "1") { authMode = .password }
        else { authMode = .keyAgent }
        let directory = try value("RemoteDirectory")
        var username = try value("UserName")
        if username.isEmpty, (kind == .ftp || kind == .ftps), raw("LoginType") == "0" { username = "anonymous" }
        let profile = NetworkConnection(kind: kind, host: try value("HostName"), port: port,
            username: username, rootPath: directory.isEmpty ? "/" : directory, privateKeyPath: key.isEmpty ? nil : key,
            timeoutSeconds: timeout ?? 15, sftpAuthenticationMode: kind == .sftp ? authMode : .keyAgent)
        let named = try SavedNetworkProfiles.assigningPath(unescape(encodedName), to: profile)
        try named.validate()
        return named
    }

    public static func encode(_ profile: NetworkConnection) throws -> Data {
        try profile.validate()
        guard profile.sftpJumpHosts.isEmpty else {
            throw NetworkError.unsupported("Экспорт сессии с промежуточными SSH-серверами в NetBox недоступен.")
        }
        guard profile.privateKeyPath?.lowercased().hasSuffix(".ppk") != true else {
            throw NetworkError.unsupported("Путь к ключу PuTTY нельзя перенести этим экспортом.")
        }
        let path = SavedNetworkProfiles.path(for: profile)
        let named = try SavedNetworkProfiles.assigningPath(path, to: profile)
        guard named.profileGroup == profile.profileGroup, profile.name.isEmpty || named.name == profile.name else {
            throw NetworkError.invalidPath(path)
        }
        let protocolName: String, encryption: String
        switch profile.kind {
        case .sftp: (protocolName, encryption) = ("SFTP", "0")
        case .ftp: (protocolName, encryption) = ("FTP", "0")
        case .ftps: (protocolName, encryption) = ("FTP", "3")
        case .webdav: (protocolName, encryption) = ("WebDAV", "0")
        case .webdavs: (protocolName, encryption) = ("WebDAV", "1")
        }
        let root = XMLElement(name: "NetBox")
        root.addAttribute(XMLNode.attribute(withName: "version", stringValue: "2.1") as! XMLNode)
        let sessions = XMLElement(name: "Sessions")
        root.addChild(sessions)
        let session = XMLElement(name: "Session")
        session.addAttribute(XMLNode.attribute(withName: "name", stringValue: escape(path)) as! XMLNode)
        sessions.addChild(session)
        let fields = [("HostName", profile.host), ("PortNumber", String(profile.port)),
                      ("UserName", profile.username), ("FSProtocol", protocolName),
                      ("Ftps", encryption), ("RemoteDirectory", profile.rootPath),
                      ("Timeout", String(Int(profile.timeoutSeconds.rounded()))),
                      ("PublicKeyFile", profile.privateKeyPath ?? "")]
        for (key, value) in fields { session.addChild(XMLElement(name: key, stringValue: escape(value))) }
        if profile.kind == .sftp {
            let mode = profile.sftpAuthenticationMode
            session.addChild(XMLElement(name: "TryAgent", stringValue: mode == .password ? "0" : "1"))
            session.addChild(XMLElement(name: "AuthKI", stringValue: mode == .keyAgent ? "0" : "1"))
            session.addChild(XMLElement(name: "AuthKIPassword", stringValue: mode == .password ? "1" : "0"))
        }
        let document = XMLDocument(rootElement: root)
        document.characterEncoding = "UTF-8"
        return document.xmlData(options: [.nodePrettyPrint])
    }

    public static func fileName(for profile: NetworkConnection) -> String {
        // Escape the group separators for a flat destination, independently of the XML session name.
        let path = SavedNetworkProfiles.path(for: profile)
        let safe = escape(path).replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: ":", with: "%3A")
        return (safe.utf8.count <= 235 ? safe : profile.id.uuidString) + ".netbox"
    }

    private static func escape(_ value: String) -> String {
        let bytes = Array(value.utf8)
        let source = bytes.contains(where: { $0 > 127 }) ? [0xef, 0xbb, 0xbf] + bytes : bytes
        return source.enumerated().map { index, byte in
            if byte <= 32 || byte >= 127 || [37, 42, 63, 92].contains(byte) || (index == 0 && byte == 46) {
                return String(format: "%%%02X", byte)
            }
            return String(UnicodeScalar(byte))
        }.joined()
    }

    private static func unescape(_ value: String) throws -> String {
        let bytes = Array(value.utf8)
        var output: [UInt8] = [], index = 0
        while index < bytes.count {
            if bytes[index] == 37, index + 2 < bytes.count,
               let decoded = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                output.append(decoded)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        if output.starts(with: [0xef, 0xbb, 0xbf]) { output.removeFirst(3) }
        guard let result = String(bytes: output, encoding: .utf8) else {
            throw NetworkError.unsupported("Сессия NetBox записана в неподдерживаемой кодировке Windows.")
        }
        return result
    }
}
