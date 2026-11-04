import Foundation
import CoreFoundation
import Darwin

/// Ten common lists retain SearchResult's original identity/content stamps.
/// Neither switching nor persistence recaptures a file at its current path.
public struct TemporaryPanelLibrary: Codable, Sendable {
    public static let slotCount = 10
    public static let maximumBytes = 32 * 1024 * 1024
    public private(set) var version: Int = 1
    public private(set) var slots: [[SearchResult]]
    public private(set) var lastOpenedSlot: Int?
    public init() { slots = Array(repeating: [], count: Self.slotCount) }
    public func items(in slot: Int) throws -> [SearchResult] {
        try Self.checkSlot(slot); return slots[slot]
    }
    public mutating func select(_ slot: Int) throws { try Self.checkSlot(slot); lastOpenedSlot = slot }

    /// A same-path replacement must not bless a changed source. Clear the slot
    /// explicitly before capturing a replacement identity in a later operation.
    public mutating func replace(_ items: [SearchResult], in slot: Int) throws {
        try Self.checkSlot(slot)
        let previous = Dictionary(slots[slot].map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unique = try TemporaryPanelItems.merging([], items)
        let preserved = unique.map { previous[$0.id] ?? $0 }
        try Self.validateItems(preserved)
        slots[slot] = preserved
    }
    public mutating func append(_ items: [SearchResult], to slot: Int) throws {
        try Self.checkSlot(slot)
        let merged = try TemporaryPanelItems.merging(slots[slot], items)
        try Self.validateItems(merged); slots[slot] = merged
    }
    public mutating func clear(_ slot: Int) throws { try Self.checkSlot(slot); slots[slot] = [] }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw PanelSessionError("Общие временные панели превышают 32 МиБ.") }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw PanelSessionError("Общие временные панели превышают 32 МиБ.") }
        // Reject a deeply nested foreign document before either JSON decoder.
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 12 else { throw PanelSessionError("Слишком глубокая структура общих панелей.") }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "slots", "lastOpenedSlot"]),
              let number = object["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number == 1 else {
            throw PanelSessionError("Неверный формат общих временных панелей версии 1.")
        }
        let library = try JSONDecoder().decode(Self.self, from: data)
        try library.validate(); return library
    }
    private static func checkSlot(_ slot: Int) throws {
        guard (0..<slotCount).contains(slot) else { throw PanelSessionError("Номер общей временной панели должен быть от 0 до 9.") }
    }
    private static func validateItems(_ items: [SearchResult]) throws {
        guard items.count <= 10_000, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ item in
                  item.url.isFileURL && (item.url.host == nil || item.url.host == "" || item.url.host == "localhost") && item.url.path.hasPrefix("/") &&
                  !item.url.path.contains("\0") && item.url.path.utf8.count <= 16_384 && item.name == item.url.lastPathComponent &&
                  item.size >= 0 && (item.snippet?.utf8.count ?? 0) <= 65_536
              }) else { throw PanelSessionError("Общая панель должна содержать до 10 000 уникальных локальных снимков.") }
    }
    private func validate() throws {
        guard version == 1, slots.count == Self.slotCount else { throw PanelSessionError("Нужно ровно 10 общих временных панелей версии 1.") }
        if let lastOpenedSlot { try Self.checkSlot(lastOpenedSlot) }
        for items in slots { try Self.validateItems(items) }
    }
}

/// Private atomic storage with optimistic conflict checks. A changed/replaced
/// library must be explicitly reloaded; malformed originals are never overwritten.
public final class TemporaryPanelLibraryStore {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FarForMac/TemporaryPanels", isDirectory: true).appendingPathComponent("panels.json")
    }
    public let url: URL
    private struct Identity: Equatable {
        let device: dev_t, inode: ino_t
        let size: off_t
        let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }
    private enum Baseline: Equatable { case missing, file(Identity, Data) }
    private var baseline: Baseline?
    public init(url: URL = TemporaryPanelLibraryStore.defaultURL) { self.url = url }
    public func load() throws -> TemporaryPanelLibrary {
        let snapshot = try read()
        let library: TemporaryPanelLibrary
        switch snapshot {
        case .missing: library = TemporaryPanelLibrary()
        case .file(_, let data): library = try TemporaryPanelLibrary.decode(data)
        }
        baseline = snapshot
        return library
    }
    public func save(_ library: TemporaryPanelLibrary) throws {
        let data = try library.encoded()
        guard let baseline else { throw PanelSessionError("Сначала загрузите общие панели, чтобы сохранить их без перезаписи чужих изменений.") }
        guard try read() == baseline else { throw PanelSessionError("Общие панели изменены другим окном или процессом. Перезагрузите список перед сохранением.") }
        if case .file(_, let original) = baseline, original == data { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var folder = stat()
        guard lstat(directory.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR, folder.st_uid == getuid(), folder.st_mode & 0o077 == 0 else {
            throw PanelSessionError("Папка общих панелей должна быть приватной папкой пользователя, без символической ссылки.")
        }
        let temporary = directory.appendingPathComponent(".panels-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PanelSessionError("Не удалось создать файл общих панелей.") }
        defer { Darwin.close(fd); _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw PanelSessionError("Не удалось записать общие панели.") }
                offset += amount
            }
        }
        var currentFolder = stat()
        guard fsync(fd) == 0, try read() == baseline,
              lstat(directory.path, &currentFolder) == 0, currentFolder.st_dev == folder.st_dev, currentFolder.st_ino == folder.st_ino,
              rename(temporary.path, url.path) == 0 else {
            throw PanelSessionError("Общие панели изменились во время сохранения или недоступны. Исходный файл сохранён.")
        }
        self.baseline = try read()
    }
    private func read() throws -> Baseline {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { throw PanelSessionError("Нужен локальный файл общих панелей.") }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return .missing }
            throw PanelSessionError("Не удалось открыть общие панели; ссылки и специальные файлы не поддерживаются.")
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_mode & 0o077 == 0,
              before.st_size >= 0, before.st_size <= TemporaryPanelLibrary.maximumBytes else {
            throw PanelSessionError("Общие панели должны храниться в обычном приватном файле до 32 МиБ.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let amount = Darwin.read(fd, &buffer, buffer.count)
            if amount < 0 && errno == EINTR { continue }
            guard amount >= 0 else { throw PanelSessionError("Не удалось прочитать общие панели.") }
            if amount == 0 { break }
            guard data.count + amount <= TemporaryPanelLibrary.maximumBytes else { throw PanelSessionError("Общие панели выросли сверх 32 МиБ.") }
            data.append(contentsOf: buffer.prefix(amount))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, Identity(before) == Identity(after) else { throw PanelSessionError("Общие панели изменились во время чтения.") }
        return .file(Identity(after), data)
    }
}
