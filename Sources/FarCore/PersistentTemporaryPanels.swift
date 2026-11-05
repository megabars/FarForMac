import Foundation
import CoreFoundation
import Darwin

/// Ten reusable mixed lists plus the last mixed panel; loading never restores providers.
public struct PersistentTemporaryPanels: Codable, Sendable {
    public static let slotCount = 10
    public static let maximumCount = 10_000
    public static let maximumBytes = 32 * 1024 * 1024
    public private(set) var version = 1
    public private(set) var slots: [[SavedSearchReference]]
    public private(set) var lastOpenedSlot: Int?
    public private(set) var lastMixed: [SavedSearchReference] = []
    public init() { slots = Array(repeating: [], count: Self.slotCount) }
    public func items(in slot: Int) throws -> [SavedSearchReference] { try Self.checkSlot(slot); return slots[slot] }
    public mutating func select(_ slot: Int) throws { try Self.checkSlot(slot); lastOpenedSlot = slot }
    public mutating func replace(_ matches: [SearchMatch], in slot: Int) throws {
        try replaceReferences(matches.map { try SavedSearchReference(capturing: $0) }, in: slot)
    }
    public mutating func append(_ matches: [SearchMatch], to slot: Int) throws {
        try Self.checkSlot(slot)
        let merged = try Self.merge(slots[slot], matches.map { try SavedSearchReference(capturing: $0) })
        slots[slot] = merged
    }
    public mutating func clear(_ slot: Int) throws { try Self.checkSlot(slot); slots[slot] = [] }
    public mutating func setLastMixed(_ matches: [SearchMatch]) throws {
        let references = try matches.map { try SavedSearchReference(capturing: $0) }
        // This is the current independent collection, not an append to a shared slot.
        // Its rows already carry immutable snapshots; never reread a source here.
        // A new search may explicitly produce a new snapshot for the same path.
        lastMixed = try Self.merge([], references)
    }
    public mutating func clearLastMixed() { lastMixed = [] }
    mutating func replaceReferences(_ references: [SavedSearchReference], in slot: Int) throws {
        try Self.checkSlot(slot)
        let previous = Dictionary(slots[slot].map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        slots[slot] = try Self.merge([], references.map { previous[$0.id] ?? $0 })
    }
    private static func merge(_ original: [SavedSearchReference], _ additions: [SavedSearchReference]) throws -> [SavedSearchReference] {
        var ids = Set(original.map(\.id)), result = original
        for reference in additions {
            try reference.validate()
            if ids.insert(reference.id).inserted { result.append(reference) }
            guard result.count <= maximumCount else { throw PanelSessionError("Временная панель содержит более 10 000 результатов.") }
        }
        return result
    }
    private static func checkSlot(_ slot: Int) throws {
        guard (0..<slotCount).contains(slot) else { throw PanelSessionError("Номер общей временной панели должен быть от 0 до 9.") }
    }
    private func validate() throws {
        guard version == 1, slots.count == Self.slotCount else { throw PanelSessionError("Нужно ровно 10 смешанных панелей версии 1.") }
        if let lastOpenedSlot { try Self.checkSlot(lastOpenedSlot) }
        for list in slots + [lastMixed] {
            guard list.count <= Self.maximumCount, Set(list.map(\.id)).count == list.count else { throw PanelSessionError("В смешанной панели допускается до 10 000 уникальных результатов.") }
            for reference in list { try reference.validate() }
        }
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw PanelSessionError("Смешанные панели превышают 32 МиБ.") }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw PanelSessionError("Смешанные панели превышают 32 МиБ.") }
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 16 else { throw PanelSessionError("Слишком глубокая структура смешанных панелей.") }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
        let object = try JSONSerialization.jsonObject(with: data)
        try SavedPanelsJSON.validate(object)
        let library = try JSONDecoder().decode(Self.self, from: data)
        try library.validate(); return library
    }
}

/// Reject unknown fields too, so foreign credentials or future schemas are not silently ignored.
private enum SavedPanelsJSON {
    static func dictionary(_ object: Any, keys: Set<String>) throws -> [String: Any] {
        guard let value = object as? [String: Any], Set(value.keys).isSubset(of: keys) else { throw PanelSessionError("Неизвестные поля смешанных панелей.") }
        return value
    }
    static func validate(_ object: Any) throws {
        let root = try dictionary(object, keys: ["version", "slots", "lastOpenedSlot", "lastMixed"])
        guard let version = root["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let slots = root["slots"] as? [[Any]], slots.count == PersistentTemporaryPanels.slotCount,
              let last = root["lastMixed"] as? [Any] else { throw PanelSessionError("Неверный формат смешанных панелей версии 1.") }
        for list in slots + [last] {
            guard list.count <= PersistentTemporaryPanels.maximumCount else { throw PanelSessionError("Слишком много сохранённых результатов.") }
            for reference in list { try item(reference) }
        }
    }
    static let stampKeys: Set<String> = ["device", "inode", "mode", "size", "seconds", "nanoseconds", "changedSeconds", "changedNanoseconds"]
    static func item(_ object: Any) throws {
        let value = try dictionary(object, keys: ["local", "archive", "remote"])
        guard value.count == 1, let kind = value.keys.first, let body = value[kind] else { throw PanelSessionError("Неверный тип сохранённого результата.") }
        let wrapper = try dictionary(body, keys: ["_0"])
        guard wrapper.count == 1, let payload = wrapper["_0"] else { throw PanelSessionError("Неверный снимок сохранённого результата.") }
        switch kind {
        case "local":
            let result = try dictionary(payload, keys: ["capturedIdentityPath", "url", "name", "isDirectory", "isSymbolicLink", "size", "modified", "snippet", "lineNumber", "byteOffset", "stamp", "contentStamp"])
            if let stamp = result["stamp"] { _ = try dictionary(stamp, keys: stampKeys) }
            if let stamp = result["contentStamp"], !(stamp is NSNull) { _ = try dictionary(stamp, keys: stampKeys) }
        case "archive":
            let result = try dictionary(payload, keys: ["identity", "entry", "isReadOnly", "snippet", "lineNumber", "byteOffset"])
            if let entry = result["entry"] { try archiveEntry(entry) }
            if let object = result["identity"] {
                let identity = try dictionary(object, keys: ["sourceURL", "logicalSourcePath", "memberChain", "stamp"])
                if let stamp = identity["stamp"] { _ = try dictionary(stamp, keys: ["device", "inode", "size", "modifiedSeconds", "modifiedNanoseconds", "changedSeconds", "changedNanoseconds"]) }
                guard let chain = identity["memberChain"] as? [Any], chain.count <= 4 else { throw PanelSessionError("Недопустимая цепочка вложенных архивов.") }
                for entry in chain { try archiveEntry(entry) }
            }
        case "remote":
            let result = try dictionary(payload, keys: ["connection", "entry", "snippet", "lineNumber", "byteOffset"])
            if let entry = result["entry"] { _ = try dictionary(entry, keys: ["path", "isDirectory", "isSymbolicLink", "size", "modified", "version"]) }
            if let object = result["connection"] {
                let connection = try dictionary(object, keys: ["id", "name", "profileGroup", "kind", "host", "port", "username", "rootPath", "privateKeyPath", "timeoutSeconds", "sftpAuthenticationMode", "sftpJumpHosts"])
                if let jumps = connection["sftpJumpHosts"] as? [Any] {
                    guard jumps.count <= 4 else { throw PanelSessionError("Слишком много SSH-шлюзов.") }
                    for jump in jumps { _ = try dictionary(jump, keys: ["host", "port", "username", "privateKeyPath", "authenticationMode"]) }
                }
            }
        default: throw PanelSessionError("Неизвестный тип сохранённого результата.")
        }
    }
    static func archiveEntry(_ object: Any) throws { _ = try dictionary(object, keys: ["path", "isDirectory", "size", "modificationDate", "isEncrypted"]) }
}

public final class PersistentTemporaryPanelsStore {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FarForMac/TemporaryPanels", isDirectory: true).appendingPathComponent("mixed-panels.json")
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
    public let legacyURL: URL
    public init(url: URL = PersistentTemporaryPanelsStore.defaultURL, legacyURL: URL? = nil) {
        self.url = url
        self.legacyURL = legacyURL ?? url.deletingLastPathComponent().appendingPathComponent("panels.json")
    }
    public func load() throws -> PersistentTemporaryPanels {
        let snapshot = try read()
        let library: PersistentTemporaryPanels
        switch snapshot {
        case .missing:
            var migrated = PersistentTemporaryPanels()
            // The v1 store validates its private file, schema, bounds and original stamps.
            let old = try TemporaryPanelLibraryStore(url: legacyURL).load()
            for slot in 0..<PersistentTemporaryPanels.slotCount {
                try migrated.replace(old.items(in: slot).map(SearchMatch.local), in: slot)
            }
            if let slot = old.lastOpenedSlot { try migrated.select(slot) }
            library = migrated
        case .file(_, let data): library = try PersistentTemporaryPanels.decode(data)
        }
        baseline = snapshot
        // Publish the migration once. The legacy file remains untouched.
        if case .missing = snapshot, FileManager.default.fileExists(atPath: legacyURL.path) { try save(library) }
        return library
    }
    public func save(_ library: PersistentTemporaryPanels) throws {
        let data = try library.encoded()
        guard let baseline else { throw PanelSessionError("Сначала загрузите общие панели, чтобы сохранить их без перезаписи чужих изменений.") }
        guard try read() == baseline else { throw PanelSessionError("Общие панели изменены другим окном или процессом. Перезагрузите список перед сохранением.") }
        if case .file(_, let original) = baseline, original == data { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folderFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folderFD >= 0 else { throw PanelSessionError("Не удалось открыть приватную папку смешанных панелей.") }
        defer { Darwin.close(folderFD) }
        var folder = stat()
        guard fstat(folderFD, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR, folder.st_uid == getuid(), folder.st_mode & 0o077 == 0 else {
            throw PanelSessionError("Папка общих панелей должна быть приватной папкой пользователя, без символической ссылки.")
        }
        let temporary = ".mixed-panels-\(UUID().uuidString).tmp"
        let fd = openat(folderFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PanelSessionError("Не удалось создать файл общих панелей.") }
        defer { Darwin.close(fd); _ = unlinkat(folderFD, temporary, 0) }
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
              renameat(folderFD, temporary, folderFD, url.lastPathComponent) == 0 else {
            throw PanelSessionError("Общие панели изменились во время сохранения или недоступны. Исходный файл сохранён.")
        }
        _ = fsync(folderFD)
        self.baseline = try read()
    }
    private func read() throws -> Baseline {
        try SavedReferenceValidation.localURL(url)
        let directory = url.deletingLastPathComponent()
        let folderFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folderFD < 0 {
            if errno == ENOENT { return .missing }
            throw PanelSessionError("Папка смешанных панелей не должна быть ссылкой или специальным файлом.")
        }
        defer { Darwin.close(folderFD) }
        var folder = stat()
        guard fstat(folderFD, &folder) == 0, folder.st_uid == getuid(), folder.st_mode & 0o077 == 0 else {
            throw PanelSessionError("Папка смешанных панелей должна быть приватной папкой пользователя.")
        }
        let fd = openat(folderFD, url.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return .missing }
            throw PanelSessionError("Не удалось открыть общие панели; ссылки и специальные файлы не поддерживаются.")
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_mode & 0o077 == 0,
              before.st_size >= 0, before.st_size <= PersistentTemporaryPanels.maximumBytes else {
            throw PanelSessionError("Общие панели должны храниться в обычном приватном файле до 32 МиБ.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let amount = Darwin.read(fd, &buffer, buffer.count)
            if amount < 0 && errno == EINTR { continue }
            guard amount >= 0 else { throw PanelSessionError("Не удалось прочитать общие панели.") }
            if amount == 0 { break }
            guard data.count + amount <= PersistentTemporaryPanels.maximumBytes else { throw PanelSessionError("Общие панели выросли сверх 32 МиБ.") }
            data.append(contentsOf: buffer.prefix(amount))
        }
        var after = stat(), namedFolder = stat(), namedFile = stat()
        guard fstat(fd, &after) == 0, Identity(before) == Identity(after),
              lstat(directory.path, &namedFolder) == 0, namedFolder.st_dev == folder.st_dev, namedFolder.st_ino == folder.st_ino,
              fstatat(folderFD, url.lastPathComponent, &namedFile, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(namedFile) == Identity(after) else { throw PanelSessionError("Общие панели изменились во время чтения.") }
        return .file(Identity(after), data)
    }
}
