import Foundation
import Darwin

public struct EditorRecoveryRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var sourceURL: URL?
    public var text: String
    public var format: EditorFormat
    public var selection: Int
    public var modified: Date
    public var baseIdentity: String?
    public init(id: UUID = UUID(), sourceURL: URL? = nil, text: String,
                format: EditorFormat = EditorFormat(), selection: Int = 0,
                modified: Date = Date(), baseIdentity: String? = nil) {
        self.id = id; self.sourceURL = sourceURL; self.text = text; self.format = format
        self.selection = selection; self.modified = modified; self.baseIdentity = baseIdentity
    }
}

public enum EditorRecoveryError: Error, LocalizedError, Equatable {
    case invalidRecord(URL), tooLarge, invalidDirectory, loadLimit, io(String)
    public var errorDescription: String? {
        switch self {
        case .invalidRecord(let url): return "Не удалось прочитать запись восстановления: \(url.path). Файл сохранён для проверки."
        case .tooLarge: return "Запись восстановления превышает допустимый размер."
        case .invalidDirectory: return "Каталог восстановления должен быть локальным каталогом текущего пользователя."
        case .loadLimit: return "Достигнут предел восстановления: 100 записей или 64 МиБ за один запуск. Остальные файлы черновиков сохранены."
        case .io(let message): return message
        }
    }
}

public struct EditorRecoveryLoadResult: Sendable {
    public let records: [EditorRecoveryRecord]
    public let warnings: [String]
}

/// A private, injectable store. Recovery records never write to sourceURL.
/// Malformed records are reported and retained for deliberate inspection/removal.
public final class EditorRecoveryStore: @unchecked Sendable {
    public let directory: URL
    public static let maximumRecordSize = EditorDocument.maximumSize * 6 + 65_536
    public static let maximumLoadSize = 64 * 1_024 * 1_024
    public static let maximumLoadCount = 100
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FarForMac/Recovery", isDirectory: true)
    }

    public func save(_ record: EditorRecoveryRecord) throws {
        lock.lock(); defer { lock.unlock() }
        guard valid(record) else { throw EditorRecoveryError.invalidRecord(fileURL(record.id)) }
        // A buffer can temporarily contain characters unavailable in its chosen
        // code page. Recovery preserves that text even when saving is refused.
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumRecordSize else { throw EditorRecoveryError.tooLarge }
        try prepareDirectory()
        let stage = directory.appendingPathComponent(".recovery-" + UUID().uuidString)
        let fd = open(stage.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ioError() }
        defer { close(fd); _ = unlink(stage.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ioError() }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ioError() }
        guard rename(stage.path, fileURL(record.id).path) == 0 else { throw ioError() }
        flushDirectory()
    }

    public func loadAll() throws -> [EditorRecoveryRecord] {
        lock.lock(); defer { lock.unlock() }
        let result = try scan()
        if let issue = result.issues.first { throw issue }
        return result.records
    }

    /// Startup can recover healthy drafts even if another record is damaged.
    /// Warnings include paths and limit notices; every skipped file is retained.
    public func loadAvailable() throws -> EditorRecoveryLoadResult {
        lock.lock(); defer { lock.unlock() }
        let result = try scan()
        return EditorRecoveryLoadResult(records: result.records, warnings: result.issues.map(\.localizedDescription))
    }

    private func scan() throws -> (records: [EditorRecoveryRecord], issues: [EditorRecoveryError]) {
        guard directory.isFileURL else { throw EditorRecoveryError.invalidDirectory }
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
        try prepareDirectory()
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map(\.standardizedFileURL)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var records: [EditorRecoveryRecord] = []
        var issues: [EditorRecoveryError] = [], total = 0
        for (index, url) in urls.enumerated() {
            guard index < Self.maximumLoadCount else { issues.append(.loadLimit); break }
            do {
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                      info.st_size <= Self.maximumRecordSize else { throw EditorRecoveryError.invalidRecord(url) }
                let source = try LocalViewerSource(url: url)
                guard source.size <= Self.maximumRecordSize else { throw EditorRecoveryError.invalidRecord(url) }
                guard source.size <= Self.maximumLoadSize - total else { issues.append(.loadLimit); break }
                total += Int(source.size)
                var data = Data(), offset: Int64 = 0
                while offset < source.size {
                    let chunk = try source.read(offset: offset, count: Int(min(Int64(LocalViewerSource.maximumReadCount), source.size - offset)))
                    data.append(chunk); offset += Int64(chunk.count)
                }
                let record = try JSONDecoder().decode(EditorRecoveryRecord.self, from: data)
                guard url.lastPathComponent == record.id.uuidString + ".json", valid(record) else {
                    throw EditorRecoveryError.invalidRecord(url)
                }
                records.append(record)
            } catch { issues.append(.invalidRecord(url)) }
        }
        return (records.sorted { $0.modified > $1.modified }, issues)
    }

    public func remove(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try prepareDirectory()
        if unlink(fileURL(id).path) != 0, errno != ENOENT { throw ioError() }
        flushDirectory()
    }

    private func valid(_ record: EditorRecoveryRecord) -> Bool {
        guard record.text.utf8.count <= EditorDocument.maximumSize * 4,
              record.selection >= 0, record.selection <= record.text.utf16.count,
              record.modified.timeIntervalSince1970.isFinite,
              record.sourceURL == nil || record.sourceURL!.isFileURL,
              record.baseIdentity?.utf8.count ?? 0 <= 4_096,
              record.format.encoding != .automatic else { return false }
        return !record.format.bom || [ViewerEncoding.utf8, .utf16LE, .utf16BE].contains(record.format.encoding)
    }

    private func prepareDirectory() throws {
        guard directory.isFileURL else { throw EditorRecoveryError.invalidDirectory }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw EditorRecoveryError.invalidDirectory }
        guard chmod(directory.path, 0o700) == 0 else { throw ioError() }
    }
    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private func ioError() -> EditorRecoveryError { .io(String(cString: strerror(errno))) }
    private func flushDirectory() {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }
}
