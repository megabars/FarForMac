import Foundation
import CoreFoundation
import Darwin

public enum FileDescriptionError: Error, LocalizedError, Equatable {
    case changed, tooLarge, invalidEncoding, unrepresentableEncoding, unsupportedFormat, invalidName, invalidDescription, notRegularFile
    case io(String)
    public var errorDescription: String? {
        switch self {
        case .changed: return "Файл descript.ion изменился. Перечитайте описания перед сохранением."
        case .tooLarge: return "Файл описаний превышает допустимый размер 2 МиБ или 20 000 строк."
        case .invalidEncoding: return "Файл описаний не соответствует выбранной кодировке. Выберите UTF-8, Windows-1251 или DOS-866 явно; исходные байты сохранены."
        case .unrepresentableEncoding: return "Имя или описание нельзя записать в выбранной кодировке без потери символов. Исходные байты сохранены."
        case .unsupportedFormat: return "Неоднозначный формат descript.ion: проверьте кавычки, имена и повторяющиеся записи."
        case .invalidName: return "Это имя нельзя представить в descript.ion: недопустимы кавычки, переносы строк и пути."
        case .invalidDescription: return "Описание слишком длинное или содержит недопустимые управляющие символы."
        case .notRegularFile: return "descript.ion должен быть обычным файлом, а не ссылкой или специальным объектом."
        case .io(let message): return message
        }
    }
}

/// Legacy code pages are explicit: no heuristic decoding or lossy fallback.
public enum FileDescriptionEncoding: String, Codable, CaseIterable, Sendable {
    case utf8, windows1251, dos866
    public var title: String {
        switch self { case .utf8: return "UTF-8"; case .windows1251: return "Windows-1251"; case .dos866: return "DOS-866" }
    }
    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .windows1251: return .windowsCP1251
        case .dos866: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosRussian.rawValue)))
        }
    }
    public static func directoryKey(_ directory: URL) -> String { directory.standardizedFileURL.resolvingSymlinksInPath().path }
}

/// A bounded descript.ion snapshot. Untouched records retain their exact
/// bytes, spacing, order, BOM and line endings. Legacy code pages are selected
/// explicitly and must round-trip exactly. Filenames are matched without case folding.
public struct FileDescriptions: Sendable {
    public static let maximumSize = 2 * 1_024 * 1_024
    public static let maximumLines = 20_000
    public let directory: URL
    public let encoding: FileDescriptionEncoding
    public private(set) var descriptions: [String: String]
    private let originalDescriptions: [String: String]
    private let original: Data?
    private let identity: Identity?
    private let directoryIdentity: String
    private let lines: [Line]
    private let bom: Bool
    private let ending: String
    private struct Line: Sendable { let text: String; let ending: String; let owner: String? }
    private struct Identity: Equatable, Sendable {
        let value: String
        init(_ info: stat) {
            value = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mode):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }
    }

    public static func load(directory: URL, encoding: FileDescriptionEncoding = .utf8) throws -> Self {
        guard directory.isFileURL else { throw FileDescriptionError.invalidName }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let fd = try openDirectory(directory)
        defer { close(fd) }
        let directoryID = try directoryID(fd)
        let (data, identity) = try read(fd)
        let bytes = data ?? Data()
        let bom = encoding == .utf8 && bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let body = bom ? Data(bytes.dropFirst(3)) : bytes
        guard let text = String(data: body, encoding: encoding.stringEncoding),
              text.data(using: encoding.stringEncoding, allowLossyConversion: false) == body else {
            throw FileDescriptionError.invalidEncoding
        }
        let parsed = try parse(text)
        return Self(directory: directory, encoding: encoding, descriptions: parsed.1, originalDescriptions: parsed.1,
                    original: data, identity: identity, directoryIdentity: directoryID, lines: parsed.0,
                    bom: bom, ending: parsed.0.first(where: { !$0.ending.isEmpty })?.ending ?? "\r\n")
    }

    public func description(for filename: String) -> String { descriptions[filename] ?? "" }

    public mutating func setDescription(_ text: String, for filename: String) throws {
        try Self.validateName(filename)
        guard text.utf8.count <= 65_536,
              text.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\t" || $0 == "\n" || $0 == "\r" }) else {
            throw FileDescriptionError.invalidDescription
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let value = normalized.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        // FAR skips empty lines; refusing empty continuation lines avoids a lossy round trip.
        guard value.isEmpty || !value.components(separatedBy: "\n").contains(where: \.isEmpty) else {
            throw FileDescriptionError.invalidDescription
        }
        if value.isEmpty { descriptions.removeValue(forKey: filename) }
        else { descriptions[filename] = value }
    }

    /// Atomic staging and rename, with identity and byte comparison under file
    /// coordination. An uncooperative external writer can still race the final
    /// check and rename; this is not a filesystem compare-and-swap operation.
    @discardableResult public func save() throws -> Self {
        if descriptions == originalDescriptions { try verifyCurrent(); return self }
        let data = try encoded()
        let fd = try Self.openDirectory(directory)
        defer { close(fd) }
        guard try Self.directoryID(fd) == directoryIdentity else { throw FileDescriptionError.changed }
        let stage = ".far-descriptions-" + UUID().uuidString
        let output = openat(fd, stage, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw Self.ioError() }
        defer { close(output); _ = unlinkat(fd, stage, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.ioError() }
                offset += count
            }
        }
        var operationError: Error?, coordinationError: NSError?
        let url = directory.appendingPathComponent("descript.ion")
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                guard coordinated.standardizedFileURL == url,
                      try Self.directoryID(fd) == directoryIdentity else { throw FileDescriptionError.changed }
                try verify(fd)
                if identity != nil {
                    // Preserve permissions, ACLs and extended attributes without copying source bytes.
                    guard copyfile(url.path, directory.appendingPathComponent(stage).path, nil,
                                   copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC)) == 0 else { throw Self.ioError() }
                }
                guard fsync(output) == 0 else { throw Self.ioError() }
                try verify(fd)
                if original == nil {
                    guard renameatx_np(fd, stage, fd, "descript.ion", UInt32(RENAME_EXCL)) == 0 else {
                        if errno == EEXIST { throw FileDescriptionError.changed }; throw Self.ioError()
                    }
                } else {
                    guard renameat(fd, stage, fd, "descript.ion") == 0 else { throw Self.ioError() }
                }
                _ = fsync(fd)
            } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw FileDescriptionError.io(coordinationError.localizedDescription) }
        let saved = try Self.load(directory: directory, encoding: encoding)
        guard saved.original == data else { throw FileDescriptionError.changed }
        return saved
    }

    /// Verify even an unmodified snapshot before using it as operation metadata.
    public func verifyCurrent() throws {
        let fd = try Self.openDirectory(directory); defer { close(fd) }
        try verify(fd)
    }

    /// A completely emptied control file may be removed after a merged move.
    /// Nonempty bytes (including unassociated records / blank formatting) survive.
    @discardableResult func removeEmptyFileIfUnchanged() throws -> Bool {
        guard original == Data(), descriptions.isEmpty else { return original == nil }
        let fd = try Self.openDirectory(directory); defer { close(fd) }
        let url = directory.appendingPathComponent("descript.ion")
        var operationError: Error?, coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinated in
            do {
                guard coordinated.standardizedFileURL == url else { throw FileDescriptionError.changed }
                try verify(fd)
                guard unlinkat(fd, "descript.ion", 0) == 0 else { throw Self.ioError() }
                _ = fsync(fd)
            } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw FileDescriptionError.io(coordinationError.localizedDescription) }
        return true
    }

    private func verify(_ fd: Int32) throws {
        let current = try Self.read(fd)
        guard current.0 == original, current.1 == identity else { throw FileDescriptionError.changed }
        let pathFD = try Self.openDirectory(directory)
        defer { close(pathFD) }
        guard try Self.directoryID(pathFD) == directoryIdentity else { throw FileDescriptionError.changed }
    }

    private func encoded() throws -> Data {
        let changed = Set(originalDescriptions.keys).union(descriptions.keys).filter { originalDescriptions[$0] != descriptions[$0] }
        var inserted = Set<String>(), text = ""
        var lastEndings = [String: String]()
        for line in lines { if let owner = line.owner { lastEndings[owner] = line.ending } }
        func record(_ name: String, finalEnding: String) -> String {
            guard let description = descriptions[name] else { return "" }
            let quoted = name.contains(where: \.isWhitespace) ? "\"\(name)\"" : name
            let parts = description.components(separatedBy: "\n")
            return parts.enumerated().map { index, value in
                (index == 0 ? quoted + " " : " ") + value + (index == parts.count - 1 ? finalEnding : ending)
            }.joined()
        }
        for line in lines {
            if let owner = line.owner, changed.contains(owner) {
                if inserted.insert(owner).inserted {
                    let lastEnding = lastEndings[owner] ?? ending
                    text += record(owner, finalEnding: lastEnding)
                }
            } else { text += line.text + line.ending }
        }
        for name in descriptions.keys.sorted() where originalDescriptions[name] == nil {
            // CRLF is a single Swift Character; hasSuffix("\n") does not
            // recognize its final LF. Inspect the final UTF-8 byte instead.
            if let last = text.utf8.last, last != 13, last != 10 { text += ending }
            text += record(name, finalEnding: ending)
        }
        var data = bom ? Data([0xEF, 0xBB, 0xBF]) : Data()
        guard let body = text.data(using: encoding.stringEncoding, allowLossyConversion: false),
              String(data: body, encoding: encoding.stringEncoding) == text else { throw FileDescriptionError.unrepresentableEncoding }
        data.append(body)
        guard data.count <= Self.maximumSize else { throw FileDescriptionError.tooLarge }
        _ = try Self.parse(text)
        return data
    }

    private static func parse(_ text: String) throws -> ([Line], [String: String]) {
        guard !text.contains("\0") else { throw FileDescriptionError.unsupportedFormat }
        // Scan UTF-8 newline bytes: Swift treats CRLF as one Character.
        let bytes = Array(text.utf8)
        var lines = [Line](), descriptions = [String: String](), owner: String?
        var start = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count, bytes[end] != 10, bytes[end] != 13 { end += 1 }
            var next = end
            if next < bytes.count { next += 1; if bytes[end] == 13, next < bytes.count, bytes[next] == 10 { next += 1 } }
            let line = String(decoding: bytes[start..<end], as: UTF8.self)
            let terminator = String(decoding: bytes[end..<next], as: UTF8.self)
            guard lines.count < maximumLines else { throw FileDescriptionError.tooLarge }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(Line(text: line, ending: terminator, owner: nil))
            } else if line.first == " " || line.first == "\t" {
                guard let owner else { throw FileDescriptionError.unsupportedFormat }
                descriptions[owner, default: ""] += "\n" + line.trimmingCharacters(in: .whitespaces)
                lines.append(Line(text: line, ending: terminator, owner: owner))
            } else {
                let name: String, rest: Substring
                if line.first == "\"" {
                    guard let closing = line.dropFirst().firstIndex(of: "\"") else { throw FileDescriptionError.unsupportedFormat }
                    name = String(line[line.index(after: line.startIndex)..<closing])
                    rest = line[line.index(after: closing)...]
                    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { throw FileDescriptionError.unsupportedFormat }
                } else {
                    let split = line.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? line.endIndex
                    name = String(line[..<split]); rest = line[split...]
                }
                do { try validateName(name) } catch { throw FileDescriptionError.unsupportedFormat }
                guard descriptions[name] == nil else { throw FileDescriptionError.unsupportedFormat }
                descriptions[name] = rest.trimmingCharacters(in: .whitespaces)
                owner = name
                lines.append(Line(text: line, ending: terminator, owner: name))
            }
            start = next
        }
        return (lines, descriptions)
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 1_024,
              !name.contains("/"), !name.contains("\""),
              name.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && $0 != "\u{2028}" && $0 != "\u{2029}" }) else {
            throw FileDescriptionError.invalidName
        }
    }
    private static func openDirectory(_ directory: URL) throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ioError() }; return fd
    }
    private static func directoryID(_ fd: Int32) throws -> String {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw ioError() }
        return "\(info.st_dev):\(info.st_ino)"
    }
    private static func read(_ directory: Int32) throws -> (Data?, Identity?) {
        let fd = openat(directory, "descript.ion", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return (nil, nil) }
            if errno == ELOOP { throw FileDescriptionError.notRegularFile }
            throw ioError()
        }
        defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw ioError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw FileDescriptionError.notRegularFile }
        guard info.st_size >= 0, info.st_size <= maximumSize else { throw FileDescriptionError.tooLarge }
        let identity = Identity(info)
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw FileDescriptionError.changed }
                offset += count
            }
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, fstatat(directory, "descript.ion", &path, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(after) == identity, Identity(path) == identity else { throw FileDescriptionError.changed }
        return (data, identity)
    }
    private static func ioError() -> FileDescriptionError { .io(String(cString: strerror(errno))) }
}
