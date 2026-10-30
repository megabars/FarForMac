import Foundation
import Darwin
import CArchive

public enum ArchiveFormat: String, Sendable { case zip, tar }

public struct ArchiveLimits: Sendable {
    public var maximumEntries: Int
    public var maximumEntryBytes: Int64
    public var maximumTotalBytes: Int64
    public var maximumExpansionRatio: Int64
    public var maximumPathDepth: Int
    public init(maximumEntries: Int = 10_000, maximumEntryBytes: Int64 = 256 * 1024 * 1024,
                maximumTotalBytes: Int64 = 1024 * 1024 * 1024, maximumExpansionRatio: Int64 = 1_000,
                maximumPathDepth: Int = 128) {
        self.maximumEntries = maximumEntries; self.maximumEntryBytes = maximumEntryBytes
        self.maximumTotalBytes = maximumTotalBytes; self.maximumExpansionRatio = maximumExpansionRatio
        self.maximumPathDepth = maximumPathDepth
    }
    public static let `default` = ArchiveLimits()
}

public struct ArchiveEntry: Sendable, Equatable, Identifiable {
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date?
    public let isEncrypted: Bool
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public struct ArchiveProgress: Sendable {
    public let currentPath: String
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let completedItems: Int
    public let totalItems: Int
    public init(currentPath: String, completedBytes: Int64, totalBytes: Int64, completedItems: Int, totalItems: Int) {
        self.currentPath = currentPath; self.completedBytes = completedBytes; self.totalBytes = totalBytes
        self.completedItems = completedItems; self.totalItems = totalItems
    }
}

public enum ArchiveError: LocalizedError, Equatable {
    case unsupportedFormat, invalidPath(String), unsafeEntry(String), duplicatePath(String)
    case limitExceeded(String), passwordRequired, incorrectPassword, corruptArchive(String)
    case changedArchive, cancelled, io(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Поддерживаются только ZIP и несжатый TAR."
        case .invalidPath(let path): return "Небезопасный путь в архиве: \(path)"
        case .unsafeEntry(let path): return "Ссылки и специальные файлы в архиве не поддерживаются: \(path)"
        case .duplicatePath(let path): return "Конфликтующие имена в архиве: \(path)"
        case .limitExceeded(let detail): return "Превышен лимит распаковки: \(detail)"
        case .passwordRequired: return "Для извлечения требуется пароль архива."
        case .incorrectPassword: return "Неверный пароль архива."
        case .corruptArchive(let detail): return "Архив повреждён: \(detail)"
        case .changedArchive: return "Архив изменился. Откройте его заново."
        case .cancelled: return "Операция с архивом отменена."
        case .io(let detail): return "Ошибка работы с архивом: \(detail)"
        }
    }
}

public struct ArchiveSnapshot: Sendable {
    public let sourceURL: URL
    public let entries: [ArchiveEntry]
    public let format: ArchiveFormat
    public var isEncrypted: Bool { entries.contains(where: \.isEncrypted) }
    public let limits: ArchiveLimits
    fileprivate let stamp: ArchiveStamp
    public func verifyCurrent() throws {
        guard (try? ArchiveStamp(url: sourceURL)) == stamp else { throw ArchiveError.changedArchive }
    }
}

/// Owns a private directory. Keep this object alive while a viewer/editor/transfer uses its URLs.
/// The directory and all working copies are deleted on cleanup or deinitialization.
public final class ArchiveWorkspace: @unchecked Sendable {
    public let rootURL: URL
    private let lock = NSLock()
    private var removed = false
    fileprivate init() throws {
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("far-archive-XXXXXXXX").path
        var bytes = Array(template.utf8CString)
        guard let result = mkdtemp(&bytes) else { throw ArchiveError.io("Не удалось создать рабочую папку.") }
        rootURL = URL(fileURLWithPath: String(cString: result), isDirectory: true)
    }
    public func url(for path: String) throws -> URL {
        guard let safe = try ArchivePath.validate(path, directory: false, limits: .default) else { throw ArchiveError.invalidPath(path) }
        return rootURL.appendingPathComponent(safe)
    }
    public func cleanup() {
        lock.lock(); defer { lock.unlock() }
        guard !removed else { return }
        removed = true
        try? FileManager.default.removeItem(at: rootURL)
    }
    deinit { cleanup() }
}

/// Uses only the macOS libarchive API. Passwords are passed in memory; no subprocesses are used.
/// Listing validates all headers; CRC/password/data integrity is checked during extraction.
public enum ArchiveReader {
    public static var libraryVersion: String { String(cString: archive_version_string()) }
    public static func open(_ url: URL, password: String? = nil, limits: ArchiveLimits = .default,
                            cancellation: TransferCancellation = TransferCancellation(),
                            onProgress: (ArchiveProgress) -> Void = { _ in }) throws -> ArchiveSnapshot {
        try checkLimits(limits)
        let source = try ArchiveInput(url: url, password: password)
        defer { source.close() }
        try validateZIPNames(source.fd, size: source.stamp.size, limits: limits, cancellation: cancellation)
        var entries: [ArchiveEntry] = []
        var topology = ArchivePath.Topology()
        var total: Int64 = 0
        var headers = 0
        while let entry = try source.next(cancellation: cancellation) {
            headers += 1
            guard headers <= limits.maximumEntries else { throw ArchiveError.limitExceeded("число элементов") }
            if let item = try decode(entry, limits: limits) {
                try topology.insert(item)
                total = try budget(total, adding: item.size, maximum: limits.maximumTotalBytes, detail: "общий размер")
                try expansion(total, compressed: source.stamp.size, limits: limits)
                entries.append(item)
                onProgress(ArchiveProgress(currentPath: item.path, completedBytes: 0, totalBytes: total,
                                           completedItems: entries.count, totalItems: entries.count))
            }
            try source.skip()
        }
        let format = try source.format()
        try source.verify()
        return ArchiveSnapshot(sourceURL: url.standardizedFileURL, entries: entries, format: format,
                               limits: limits, stamp: source.stamp)
    }

    /// Validates the complete archive before creating any output. A nil selection extracts all files.
    /// A selected directory includes all descendants; extraction always stays in a new private workspace.
    public static func extract(_ snapshot: ArchiveSnapshot, paths: [String]? = nil, password: String? = nil,
                               cancellation: TransferCancellation = TransferCancellation(),
                               onProgress: (ArchiveProgress) -> Void = { _ in }) throws -> ArchiveWorkspace {
        try snapshot.verifyCurrent()
        try stopped(cancellation)
        let checked = try open(snapshot.sourceURL, password: password, limits: snapshot.limits, cancellation: cancellation)
        guard checked.stamp == snapshot.stamp, checked.entries == snapshot.entries, checked.format == snapshot.format else {
            throw ArchiveError.changedArchive
        }
        let selection = try paths.map { paths in
            try paths.map { path -> String in
                guard let safe = try ArchivePath.validate(path, directory: false, limits: snapshot.limits),
                      snapshot.entries.contains(where: { $0.path == safe || $0.path.hasPrefix(safe + "/") }) else {
                    throw ArchiveError.invalidPath(path)
                }
                return safe
            }
        }
        func selected(_ path: String) -> Bool {
            selection == nil || selection!.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
        }
        let selectedEntries = snapshot.entries.filter { selected($0.path) }
        let total = selectedEntries.reduce(Int64(0)) { $0 + $1.size }
        let source = try ArchiveInput(url: snapshot.sourceURL, password: password)
        defer { source.close() }
        guard source.stamp == snapshot.stamp else { throw ArchiveError.changedArchive }
        let workspace = try ArchiveWorkspace()
        var succeeded = false
        defer { if !succeeded { workspace.cleanup() } }
        let root = Darwin.open(workspace.rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ArchiveError.io("Не удалось открыть рабочую папку.") }
        defer { Darwin.close(root) }
        var bytes: Int64 = 0
        var completed = 0
        var index = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while let raw = try source.next(cancellation: cancellation) {
            guard let item = try decode(raw, limits: snapshot.limits) else { try source.skip(); continue }
            guard index < snapshot.entries.count, item == snapshot.entries[index] else { throw ArchiveError.changedArchive }
            index += 1
            guard selected(item.path) else { try source.skip(); continue }
            if item.isDirectory {
                let directory = try secureDirectory(root: root, components: item.path.split(separator: "/").map(String.init))
                Darwin.close(directory)
            } else {
                let parts = item.path.split(separator: "/").map(String.init)
                let parent = try secureDirectory(root: root, components: Array(parts.dropLast()))
                defer { Darwin.close(parent) }
                let output = openat(parent, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
                guard output >= 0 else { throw ArchiveError.io("Не удалось создать рабочую копию: \(item.path)") }
                defer { Darwin.close(output) }
                var fileBytes: Int64 = 0
                while true {
                    try stopped(cancellation)
                    let count = archive_read_data(source.archive, &buffer, buffer.count)
                    guard count >= 0 else { throw source.failure() }
                    if count == 0 { break }
                    fileBytes = try budget(fileBytes, adding: Int64(count), maximum: snapshot.limits.maximumEntryBytes, detail: item.path)
                    bytes = try budget(bytes, adding: Int64(count), maximum: snapshot.limits.maximumTotalBytes, detail: "общий размер")
                    try expansion(bytes, compressed: snapshot.stamp.size, limits: snapshot.limits)
                    guard fileBytes <= item.size else { throw ArchiveError.corruptArchive("Размер элемента не совпадает с заголовком.") }
                    try buffer.withUnsafeBytes { rawBytes in
                        var offset = 0
                        while offset < count {
                            try stopped(cancellation)
                            let written = Darwin.write(output, rawBytes.baseAddress!.advanced(by: offset), count - offset)
                            if written < 0 && errno == EINTR { continue }
                            guard written > 0 else { throw ArchiveError.io("Не удалось записать рабочую копию.") }
                            offset += written
                        }
                    }
                    onProgress(ArchiveProgress(currentPath: item.path, completedBytes: bytes, totalBytes: total,
                                               completedItems: completed, totalItems: selectedEntries.count))
                }
                guard fileBytes == item.size else { throw ArchiveError.corruptArchive("Неполные данные элемента: \(item.path)") }
            }
            completed += 1
            onProgress(ArchiveProgress(currentPath: item.path, completedBytes: bytes, totalBytes: total,
                                       completedItems: completed, totalItems: selectedEntries.count))
        }
        guard index == snapshot.entries.count else { throw ArchiveError.changedArchive }
        try source.verify()
        try snapshot.verifyCurrent()
        try stopped(cancellation)
        succeeded = true
        return workspace
    }

    private static func decode(_ entry: OpaquePointer, limits: ArchiveLimits) throws -> ArchiveEntry? {
        guard let raw = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry),
              let name = String(validatingUTF8: raw) else { throw ArchiveError.invalidPath("некорректное имя UTF-8") }
        let type = archive_entry_filetype(entry)
        guard archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
              type == S_IFREG || type == S_IFDIR else { throw ArchiveError.unsafeEntry(name) }
        let isDirectory = type == S_IFDIR
        guard let path = try ArchivePath.validate(name, directory: isDirectory, limits: limits) else { return nil }
        let size = isDirectory ? 0 : archive_entry_size(entry)
        guard size >= 0, isDirectory || archive_entry_size_is_set(entry) != 0 else {
            throw ArchiveError.corruptArchive("Не указан размер: \(path)")
        }
        guard size <= limits.maximumEntryBytes else { throw ArchiveError.limitExceeded(path) }
        let date = archive_entry_mtime_is_set(entry) != 0
            ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry)) + TimeInterval(archive_entry_mtime_nsec(entry)) / 1_000_000_000) : nil
        return ArchiveEntry(path: path, isDirectory: isDirectory, size: size, modificationDate: date,
                            isEncrypted: archive_entry_is_encrypted(entry) > 0)
    }

    private static func stopped(_ cancellation: TransferCancellation) throws {
        if cancellation.isCancelled { throw ArchiveError.cancelled }
    }
    private static func checkLimits(_ limits: ArchiveLimits) throws {
        guard limits.maximumEntries > 0, limits.maximumEntryBytes >= 0, limits.maximumTotalBytes >= 0,
              limits.maximumExpansionRatio > 0, limits.maximumPathDepth > 0 else { throw ArchiveError.limitExceeded("настройки лимитов") }
    }
    private static func budget(_ total: Int64, adding value: Int64, maximum: Int64, detail: String) throws -> Int64 {
        let (result, overflow) = total.addingReportingOverflow(value)
        guard !overflow, result <= maximum else { throw ArchiveError.limitExceeded(detail) }
        return result
    }
    private static func expansion(_ total: Int64, compressed: Int64, limits: ArchiveLimits) throws {
        let (maximum, overflow) = max(1, compressed).multipliedReportingOverflow(by: limits.maximumExpansionRatio)
        if !overflow && total > maximum { throw ArchiveError.limitExceeded("степень сжатия") }
    }
    private static func secureDirectory(root: Int32, components: [String]) throws -> Int32 {
        var current = dup(root)
        guard current >= 0 else { throw ArchiveError.io("Не удалось открыть рабочую папку.") }
        do {
            for component in components {
                if mkdirat(current, component, mode_t(0o700)) != 0 && errno != EEXIST {
                    throw ArchiveError.io("Не удалось создать папку рабочей копии.")
                }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ArchiveError.unsafeEntry(component) }
                Darwin.close(current); current = next
            }
            return current
        } catch { Darwin.close(current); throw error }
    }

    /// ZIP names are length-delimited, while libarchive's pathname API is NUL-terminated.
    /// Check the central directory before passing names through that API so embedded NULs
    /// cannot conceal a suffix. ZIP64 and multi-volume archives are deliberately unsupported.
    private static func validateZIPNames(_ fd: Int32, size: Int64, limits: ArchiveLimits, cancellation: TransferCancellation) throws {
        guard size >= 4 else { return }
        func read(_ offset: Int64, _ count: Int) throws -> [UInt8] {
            var data = [UInt8](repeating: 0, count: count)
            let received = pread(fd, &data, count, off_t(offset))
            guard received == count else { throw ArchiveError.corruptArchive("Неполная структура ZIP.") }
            return data
        }
        let signature = try read(0, 4)
        guard signature == [0x50, 0x4b, 0x03, 0x04] || signature == [0x50, 0x4b, 0x05, 0x06] else { return }
        let count = Int(min(size, 65_557))
        let tail = try read(size - Int64(count), count)
        func u16(_ bytes: [UInt8], _ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ bytes: [UInt8], _ offset: Int) -> Int64 { Int64(u16(bytes, offset)) | Int64(u16(bytes, offset + 2)) << 16 }
        var end: Int?
        if tail.count >= 22 {
            for offset in stride(from: tail.count - 22, through: 0, by: -1) {
                if Array(tail[offset..<(offset + 4)]) == [0x50, 0x4b, 0x05, 0x06],
                   offset + 22 + u16(tail, offset + 20) == tail.count { end = offset; break }
            }
        }
        guard let end else { throw ArchiveError.corruptArchive("Не найден каталог ZIP.") }
        guard u16(tail, end + 4) == 0, u16(tail, end + 6) == 0,
              u16(tail, end + 8) == u16(tail, end + 10), u16(tail, end + 10) != 65_535,
              u32(tail, end + 12) != 0xffff_ffff, u32(tail, end + 16) != 0xffff_ffff else {
            throw ArchiveError.unsupportedFormat
        }
        var offset = u32(tail, end + 16)
        let directoryEnd = offset + u32(tail, end + 12)
        guard directoryEnd <= size - Int64(count) + Int64(end) else { throw ArchiveError.corruptArchive("Неверный каталог ZIP.") }
        for _ in 0..<u16(tail, end + 10) {
            try stopped(cancellation)
            guard offset + 46 <= directoryEnd else { throw ArchiveError.corruptArchive("Неполный каталог ZIP.") }
            let header = try read(offset, 46)
            guard Array(header[0..<4]) == [0x50, 0x4b, 0x01, 0x02] else { throw ArchiveError.corruptArchive("Неверный элемент ZIP.") }
            let nameLength = u16(header, 28)
            let length = 46 + nameLength + u16(header, 30) + u16(header, 32)
            guard offset + Int64(length) <= directoryEnd else { throw ArchiveError.corruptArchive("Неполное имя ZIP.") }
            let name = try read(offset + 46, nameLength)
            guard !name.contains(0) else { throw ArchiveError.invalidPath("NUL в имени ZIP") }
            // ZIP readers may translate backslashes into slashes. Validate raw
            // length-delimited names first, before any library normalization.
            // Legacy encodings retain the ASCII path syntax checked here;
            // libarchive's decoded Unicode name is validated separately.
            _ = try ArchivePath.validate(String(decoding: name, as: UTF8.self),
                                         directory: name.last == 0x2f, limits: limits)
            let extra = try read(offset + 46 + Int64(nameLength), u16(header, 30))
            var extraOffset = 0
            while extraOffset + 4 <= extra.count {
                let identifier = u16(extra, extraOffset)
                let fieldLength = u16(extra, extraOffset + 2)
                guard extraOffset + 4 + fieldLength <= extra.count else {
                    throw ArchiveError.corruptArchive("Неполные дополнительные данные ZIP.")
                }
                // Info-ZIP Unicode path: version + original-name CRC + UTF-8 path.
                if identifier == 0x7075 && fieldLength >= 5 &&
                    extra[(extraOffset + 9)..<(extraOffset + 4 + fieldLength)].contains(0) {
                    throw ArchiveError.invalidPath("NUL в Unicode-имени ZIP")
                }
                if identifier == 0x7075 && fieldLength >= 5 {
                    let unicodeName = Array(extra[(extraOffset + 9)..<(extraOffset + 4 + fieldLength)])
                    guard let unicode = String(bytes: unicodeName, encoding: .utf8) else {
                        throw ArchiveError.invalidPath("Некорректное Unicode-имя ZIP")
                    }
                    _ = try ArchivePath.validate(unicode, directory: unicodeName.last == 0x2f, limits: limits)
                }
                extraOffset += 4 + fieldLength
            }
            guard extraOffset == extra.count else { throw ArchiveError.corruptArchive("Неверные дополнительные данные ZIP.") }
            offset += Int64(length)
        }
        guard offset == directoryEnd else { throw ArchiveError.corruptArchive("Размер каталога ZIP не совпадает.") }
    }
}

private struct ArchiveStamp: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    init(stat value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.io("Источник должен быть обычным файлом.") }
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
    init(url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw ArchiveError.io("Не удалось прочитать архив.") }
        try self.init(stat: value)
    }
}

private final class ArchiveInput {
    let fd: Int32
    let archive: OpaquePointer
    let stamp: ArchiveStamp
    let url: URL
    let hasPassword: Bool
    let hasZIPStart: Bool
    private var closed = false
    init(url: URL, password: String?) throws {
        guard url.isFileURL else { throw ArchiveError.invalidPath(url.absoluteString) }
        guard password?.contains("\0") != true else { throw ArchiveError.io("Пароль не может содержать NUL.") }
        self.url = url
        hasPassword = password != nil
        fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ArchiveError.io("Не удалось открыть архив.") }
        var prefix = [UInt8](repeating: 0, count: 4)
        let prefixCount = pread(fd, &prefix, prefix.count, 0)
        hasZIPStart = prefixCount == 4 && (prefix == [0x50, 0x4b, 0x03, 0x04] || prefix == [0x50, 0x4b, 0x05, 0x06])
        var info = stat()
        guard fstat(fd, &info) == 0 else { Darwin.close(fd); throw ArchiveError.io("Не удалось прочитать архив.") }
        do { stamp = try ArchiveStamp(stat: info) } catch { Darwin.close(fd); throw error }
        guard let value = archive_read_new() else { Darwin.close(fd); throw ArchiveError.io("Недостаточно памяти.") }
        archive = value
        archive_read_support_filter_none(archive)
        // libarchive 3.7.4's seekable-only bidder does not recognize the valid
        // 22-byte empty ZIP. Register both ZIP readers so that case can use
        // the streamable reader; our central-directory preflight still runs
        // before any entry is exposed or extracted.
        archive_read_support_format_zip(archive)
        archive_read_support_format_tar(archive)
        if let password { archive_read_add_passphrase(archive, password) }
        if archive_read_open_fd(archive, fd, 64 * 1024) != ARCHIVE_OK {
            let error = failure(); close(); throw error
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        archive_read_free(archive)
        Darwin.close(fd)
    }
    deinit { close() }
    func next(cancellation: TransferCancellation) throws -> OpaquePointer? {
        if cancellation.isCancelled { throw ArchiveError.cancelled }
        var entry: OpaquePointer?
        let result = archive_read_next_header(archive, &entry)
        if result == ARCHIVE_EOF { return nil }
        guard result == ARCHIVE_OK, let entry else { throw failure() }
        _ = try format()
        return entry
    }
    func skip() throws {
        guard archive_read_data_skip(archive) == ARCHIVE_OK else { throw failure() }
    }
    func format() throws -> ArchiveFormat {
        guard archive_filter_code(archive, 0) == ARCHIVE_FILTER_NONE else { throw ArchiveError.unsupportedFormat }
        switch archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK {
        case ARCHIVE_FORMAT_ZIP:
            guard hasZIPStart else { throw ArchiveError.unsupportedFormat }
            return .zip
        case ARCHIVE_FORMAT_TAR: return .tar
        default: throw ArchiveError.unsupportedFormat
        }
    }
    func verify() throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (try? ArchiveStamp(stat: info)) == stamp,
              (try? ArchiveStamp(url: url)) == stamp else { throw ArchiveError.changedArchive }
    }
    func failure() -> ArchiveError {
        let message = archive_error_string(archive).map { String(cString: $0) } ?? "Неизвестная ошибка чтения."
        let lower = message.lowercased()
        if lower.contains("unrecognized archive format") || lower.contains("unsupported compression") {
            return .unsupportedFormat
        }
        if lower.contains("passphrase") || lower.contains("password") || lower.contains("encrypted") || lower.contains("encryption") {
            return hasPassword ? .incorrectPassword : .passwordRequired
        }
        return .corruptArchive(message)
    }
}

private enum ArchivePath {
    static func validate(_ original: String, directory: Bool, limits: ArchiveLimits) throws -> String? {
        guard !original.contains("\0"), !original.contains("\\"), !original.hasPrefix("/"),
              !original.contains(":"), original.utf8.count <= 16_384 else { throw ArchiveError.invalidPath(original) }
        var path = original
        while path.hasPrefix("./") { path.removeFirst(2) }
        if directory { while path.hasSuffix("/") { path.removeLast() } }
        if directory && (path.isEmpty || path == ".") { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= limits.maximumPathDepth,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw ArchiveError.invalidPath(original)
        }
        return path.precomposedStringWithCanonicalMapping
    }
    struct Topology {
        private var nodes: [String: (path: String, directory: Bool, explicit: Bool)] = [:]
        mutating func insert(_ entry: ArchiveEntry) throws {
            let parts = entry.path.split(separator: "/").map(String.init)
            for length in 1...parts.count {
                let path = parts.prefix(length).joined(separator: "/")
                let key = path.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
                let final = length == parts.count
                let directory = !final || entry.isDirectory
                if let old = nodes[key] {
                    guard old.path == path, old.directory == directory, !(final && old.explicit) else {
                        throw ArchiveError.duplicatePath(entry.path)
                    }
                }
                let oldExplicit = nodes[key]?.explicit ?? false
                nodes[key] = (path, directory, oldExplicit || final)
            }
        }
    }
}
