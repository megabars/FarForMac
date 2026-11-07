import Foundation
import Darwin

public enum ActivityHistoryKind: String, Codable, CaseIterable, Sendable {
    case command, view, edit, folder
}

public struct ActivityHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: ActivityHistoryKind
    /// A command line, or an absolute local path for view/edit/folder entries.
    public let value: String
    /// Working directory in which a command was explicitly submitted.
    public let directory: String?
    public let date: Date
    public let locked: Bool?
    public var isLocked: Bool { locked == true }

    public init(id: UUID = UUID(), kind: ActivityHistoryKind, value: String,
                directory: String? = nil, date: Date = Date(), locked: Bool? = nil) {
        self.id = id; self.kind = kind; self.value = value; self.directory = directory; self.date = date; self.locked = locked
    }
}

public enum CommandHistoryError: Error, LocalizedError, Equatable {
    case invalidEntry, invalidFile, tooLarge, io(String)
    public var errorDescription: String? {
        switch self {
        case .invalidEntry: return "Некорректная или слишком длинная запись истории."
        case .invalidFile: return "История должна храниться в локальном приватном файле текущего пользователя."
        case .tooLarge: return "Файл истории превышает предел 8 МиБ."
        case .io(let message): return message
        }
    }
}

/// Dialog history is separated from executable history and keyed by the FAR field name.
public struct CommandParameterHistory: Codable, Equatable, Sendable {
    private struct Entry: Codable, Equatable, Sendable {
        let name: String
        let value: String
    }
    private var entries: [Entry] = []

    public init() {}

    public func values(for name: String) -> [String] {
        entries.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public mutating func record(_ value: String, for name: String) {
        let entry = Entry(name: name, value: value)
        guard Self.valid(entry) else { return }
        entries.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.value == value }
        entries.insert(entry, at: 0)
        trim()
    }

    fileprivate var reservedBytes: Int {
        entries.reduce(256) { $0 + ($1.name.utf8.count + $1.value.utf8.count) * 6 + 64 }
    }

    private static func valid(_ entry: Entry) -> Bool {
        !entry.name.isEmpty && entry.name.utf8.count <= 256 && !entry.name.utf8.contains(0) &&
        !entry.value.isEmpty && entry.value.utf8.count <= 4_096 && !entry.value.utf8.contains(0)
    }

    private mutating func trim() {
        var counts: [String: Int] = [:]
        entries = Array(entries.filter { entry in
            guard Self.valid(entry) else { return false }
            let key = entry.name.lowercased()
            counts[key, default: 0] += 1
            return counts[key, default: 0] <= 12
        }.prefix(100))
    }

    private enum CodingKeys: String, CodingKey { case entries }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        trim()
    }
}

/// Bounded, newest-first activity history. Loading is data-only and never runs a
/// command or navigates a panel. UI can persist the Codable value in defaults,
/// or use the private atomic file store below. Callers surface persistence errors.
public struct CommandHistory: Codable, Sendable {
    public static let maximumCapacity = 500
    public static let maximumValueBytes = ShellCommand.maximumCommandBytes
    public static let maximumStoredBytes = 8 * 1_024 * 1_024
    public private(set) var entries: [ActivityHistoryEntry]
    public let capacity: Int
    public var parameterHistory = CommandParameterHistory() { didSet { trim() } }

    public init(capacity: Int = maximumCapacity) {
        self.capacity = max(1, min(capacity, Self.maximumCapacity))
        entries = []
    }

    /// Repeating an identical activity moves it to the front. Commands with
    /// different working directories remain distinct.
    public mutating func record(kind: ActivityHistoryKind, value: String,
                                directory: String? = nil, date: Date = Date()) throws {
        let existing = entries.first { $0.kind == kind && $0.value == value && $0.directory == directory }
        let entry = ActivityHistoryEntry(id: existing?.id ?? UUID(), kind: kind, value: value, directory: directory, date: date, locked: existing?.locked)
        guard Self.valid(entry) else { throw CommandHistoryError.invalidEntry }
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        trim()
    }

    public func filtered(kind: ActivityHistoryKind? = nil, query: String = "") -> [ActivityHistoryEntry] {
        entries.filter { entry in
            (kind == nil || entry.kind == kind) && (query.isEmpty ||
                entry.value.localizedCaseInsensitiveContains(query) ||
                (entry.directory?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    public func completions(for prefix: String) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard entry.kind == .command,
                  entry.value.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil || prefix.isEmpty,
                  seen.insert(entry.value).inserted else { return nil }
            return entry.value
        }
    }

    public mutating func toggleLock(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[index]
        entries[index] = ActivityHistoryEntry(id: entry.id, kind: entry.kind, value: entry.value,
            directory: entry.directory, date: entry.date, locked: entry.isLocked ? nil : true)
    }

    public mutating func remove(id: UUID) { entries.removeAll { $0.id == id && !$0.isLocked } }
    public mutating func clear(kind: ActivityHistoryKind? = nil) {
        entries.removeAll { !$0.isLocked && (kind == nil || $0.kind == kind) }
    }
    public mutating func removeMissing(kinds: Set<ActivityHistoryKind>) {
        entries.removeAll { entry in
            guard entry.kind != .command, kinds.contains(entry.kind), !entry.isLocked else { return false }
            var info = stat()
            return fstatat(AT_FDCWD, entry.value, &info, 0) != 0 && (errno == ENOENT || errno == ENOTDIR)
        }
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FarForMac/History/activities.json")
    }

    public func save(to url: URL = Self.defaultFileURL) throws {
        guard url.isFileURL else { throw CommandHistoryError.invalidFile }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumStoredBytes else { throw CommandHistoryError.tooLarge }
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw CommandHistoryError.invalidFile }
        // Dedicated default directory is private. Do not change permissions on
        // an injected parent directory (e.g. an application's test directory).
        let stage = directory.appendingPathComponent(".history-" + UUID().uuidString)
        let descriptor = open(stage.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Self.ioError() }
        defer { close(descriptor); _ = unlink(stage.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.ioError() }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(stage.path, url.path) == 0 else { throw Self.ioError() }
        let parent = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if parent >= 0 { _ = fsync(parent); close(parent) }
    }

    /// Missing store is empty; corrupt/oversized stores throw and are retained.
    public static func load(from url: URL = defaultFileURL, capacity: Int? = nil) throws -> CommandHistory {
        guard url.isFileURL else { throw CommandHistoryError.invalidFile }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return CommandHistory(capacity: capacity ?? maximumCapacity) }
        guard descriptor >= 0 else { throw ioError() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CommandHistoryError.invalidFile }
        guard info.st_size <= maximumStoredBytes else { throw CommandHistoryError.tooLarge }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ioError() }
            if count == 0 { break }
            guard data.count + count <= maximumStoredBytes else { throw CommandHistoryError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        let stored = try JSONDecoder().decode(CommandHistory.self, from: data)
        guard let capacity else { return stored }
        var resized = CommandHistory(capacity: capacity)
        resized.entries = stored.entries
        resized.parameterHistory = stored.parameterHistory
        resized.trim()
        return resized
    }

    private mutating func trim() {
        // Reserve JSON escaping overhead. This also keeps in-memory/defaults
        // histories bounded when every submitted command is near 64 KiB.
        var bytes = parameterHistory.reservedBytes, kept = Set<UUID>()
        for entry in entries.filter(\.isLocked) + entries.filter({ !$0.isLocked }) {
            let size = entry.value.utf8.count * 6 + (entry.directory?.utf8.count ?? 0) * 6 + 512
            guard kept.count < capacity, size <= Self.maximumStoredBytes - bytes else { break }
            bytes += size
            kept.insert(entry.id)
        }
        entries.removeAll { !kept.contains($0.id) }
    }

    private static func valid(_ entry: ActivityHistoryEntry) -> Bool {
        guard !entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.value.utf8.count <= maximumValueBytes, !entry.value.utf8.contains(0),
              entry.date.timeIntervalSince1970.isFinite,
              entry.directory == nil || (entry.directory!.hasPrefix("/") && !entry.directory!.utf8.contains(0) && entry.directory!.utf8.count <= 16_384)
        else { return false }
        return entry.kind == .command || (entry.value.hasPrefix("/") && entry.value.utf8.count <= 16_384)
    }
    private static func ioError() -> CommandHistoryError { .io(String(cString: strerror(errno))) }
    private enum CodingKeys: String, CodingKey { case capacity, entries, parameterHistory }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedCapacity = try container.decodeIfPresent(Int.self, forKey: .capacity) ?? Self.maximumCapacity
        capacity = max(1, min(storedCapacity, Self.maximumCapacity))
        let stored = try container.decodeIfPresent([ActivityHistoryEntry].self, forKey: .entries) ?? []
        var ids = Set<UUID>(), activities = Set<String>()
        entries = stored.filter { entry in
            guard Self.valid(entry) else { return false }
            // JSON-encoded keys avoid separator collisions in command text.
            let key = (try? JSONEncoder().encode([entry.kind.rawValue, entry.value, entry.directory ?? ""])) ?? Data()
            return ids.insert(entry.id).inserted && activities.insert(key.base64EncodedString()).inserted
        }
        parameterHistory = try container.decodeIfPresent(CommandParameterHistory.self, forKey: .parameterHistory) ?? CommandParameterHistory()
        trim()
    }
}
