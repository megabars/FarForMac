import Foundation
import Darwin
import CArchive

public enum ArchiveFormat: String, Sendable, CaseIterable {
    case zip, tar, tarGzip, tarBzip2, tarXz
    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .tarGzip: return "TAR.GZ"
        case .tarBzip2: return "TAR.BZ2"
        case .tarXz: return "TAR.XZ"
        }
    }
    public var defaultExtension: String {
        switch self {
        case .zip: return "zip"
        case .tar: return "tar"
        case .tarGzip: return "tar.gz"
        case .tarBzip2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        }
    }
    public static func suggested(by url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGzip }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz") { return .tarBzip2 }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .tarXz }
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar") { return .tar }
        return nil
    }
}

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

public struct ArchiveEntry: Codable, Sendable, Equatable, Identifiable {
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

/// Optional search accounting. Callbacks may stop a read before bytes are written.
public struct ArchiveReadObservation {
    public let header: () throws -> Void
    public let bytes: (Int64) throws -> Void
    public init(header: @escaping () throws -> Void, bytes: @escaping (Int64) throws -> Void) {
        self.header = header; self.bytes = bytes
    }
}

public enum ArchiveError: LocalizedError, Equatable {
    case unsupportedFormat, invalidPath(String), unsafeEntry(String), duplicatePath(String)
    case limitExceeded(String), passwordRequired, incorrectPassword, corruptArchive(String)
    case changedArchive, cancelled, io(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Поддерживаются ZIP, ZIP64 и TAR (без сжатия, gzip, bzip2 или xz)."
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
    fileprivate let logicalSourcePath: String
    public let entries: [ArchiveEntry]
    public let format: ArchiveFormat
    public var isEncrypted: Bool { entries.contains(where: \.isEncrypted) }
    public let limits: ArchiveLimits
    public var isReadOnly: Bool { nestedReadOnly || isEncrypted }
    fileprivate let nestedReadOnly: Bool
    fileprivate let stamp: ArchiveStamp
    fileprivate let context: ArchiveSnapshotContext?
    /// Bind automatic discovery to the file originally inspected through its directory descriptor.
    func verifyDiscoveredSource(_ value: stat) throws {
        guard try ArchiveStamp(stat: value) == stamp else { throw ArchiveError.changedArchive }
    }
    /// Logical origin, independent of a nested archive's private working path.
    var searchIdentity: String {
        if let context { return context.parent.searchIdentity + "|" + String(context.memberPath.utf8.count) + ":" + context.memberPath }
        let path = logicalSourcePath
        return String(path.utf8.count) + ":" + path
    }
    public func verifyCurrent() throws {
        try context?.parent.verifyCurrent()
        guard (try? ArchiveStamp(url: sourceURL)) == stamp else { throw ArchiveError.changedArchive }
    }
}

/// Persistent logical archive origin. Never contains private extraction paths.
public struct SavedArchiveIdentity: Codable, Sendable, Equatable {
    public let sourceURL: URL
    public let memberChain: [ArchiveEntry]
    fileprivate let logicalSourcePath: String
    fileprivate let stamp: ArchiveStamp
    fileprivate init(snapshot: ArchiveSnapshot) {
        if let context = snapshot.context {
            let parent = SavedArchiveIdentity(snapshot: context.parent)
            sourceURL = parent.sourceURL; stamp = parent.stamp; logicalSourcePath = parent.logicalSourcePath
            memberChain = parent.memberChain + [context.parent.entries.first { $0.path == context.memberPath }!]
        } else { sourceURL = snapshot.sourceURL; logicalSourcePath = snapshot.logicalSourcePath; stamp = snapshot.stamp; memberChain = [] }
    }
    public var displayPath: String { sourceURL.path + memberChain.map { " !/" + $0.path }.joined() }
    var searchIdentity: String {
        let path = logicalSourcePath
        return String(path.utf8.count) + ":" + path + memberChain.map { "|" + String($0.path.utf8.count) + ":" + $0.path }.joined()
    }
    func validate() throws {
        try SavedReferenceValidation.localURL(sourceURL)
        try SavedReferenceValidation.localPath(logicalSourcePath)
        guard memberChain.count <= ArchiveNavigationFrame.maximumDepth, stamp.size >= 0,
              (0..<1_000_000_000).contains(stamp.modifiedNanoseconds),
              (0..<1_000_000_000).contains(stamp.changedNanoseconds) else { throw PanelSessionError("Неверный снимок архива.") }
        for entry in memberChain {
            try SavedReferenceValidation.archiveEntry(entry)
            guard !entry.isDirectory else { throw PanelSessionError("Вложенный архив должен быть файлом.") }
        }
    }
    public func verifyOriginal() throws {
        guard (try? ArchiveStamp(url: sourceURL)) == stamp else { throw ArchiveError.changedArchive }
    }
    /// Opens only after matching the immutable outer source captured by the original search.
    public func restore(cancellation: TransferCancellation = TransferCancellation(),
                        password: ((URL, [String]) throws -> String?)? = nil) throws -> ArchiveSnapshot {
        try validate(); try verifyOriginal()
        if cancellation.isCancelled { throw ArchiveError.cancelled }
        let root: ArchiveSnapshot
        do { root = try ArchiveReader.open(sourceURL, cancellation: cancellation) }
        catch let error as ArchiveError where error == .passwordRequired || error == .incorrectPassword {
            root = try ArchiveReader.open(sourceURL, password: password?(sourceURL, []), cancellation: cancellation)
        }
        guard root.stamp == stamp else { throw ArchiveError.changedArchive }
        let originalRoot = ArchiveSnapshot(sourceURL: root.sourceURL, logicalSourcePath: logicalSourcePath,
            entries: root.entries, format: root.format, limits: root.limits, nestedReadOnly: root.nestedReadOnly,
            stamp: root.stamp, context: nil)
        var frame = ArchiveNavigationFrame(snapshot: originalRoot)
        var chain: [String] = []
        for entry in memberChain {
            if cancellation.isCancelled { throw ArchiveError.cancelled }
            guard frame.snapshot.entries.contains(entry) else { throw ArchiveError.changedArchive }
            let parentPassword = try entry.isEncrypted ? password?(sourceURL, chain) : nil
            chain.append(entry.path)
            do {
                frame = try frame.openNested(path: entry.path, password: parentPassword, cancellation: cancellation)
            } catch ArchiveNestedPasswordError.child(let error) where error == .passwordRequired || error == .incorrectPassword {
                frame = try frame.openNested(path: entry.path, password: parentPassword,
                    nestedPassword: password?(sourceURL, chain), cancellation: cancellation)
            }
        }
        try verifyOriginal(); try frame.verifyCurrent()
        if cancellation.isCancelled { throw ArchiveError.cancelled }
        return frame.snapshot
    }
}

public extension ArchiveSnapshot {
    var savedIdentity: SavedArchiveIdentity { SavedArchiveIdentity(snapshot: self) }
}

/// A child snapshot owns its private source and immutable ancestor snapshots.
/// Consumers may keep only the snapshot and still safely outlive panel navigation.
fileprivate final class ArchiveSnapshotContext: @unchecked Sendable {
    let parentFrame: ArchiveNavigationFrame
    var parent: ArchiveSnapshot { parentFrame.snapshot }
    let workspace: ArchiveWorkspace
    let memberPath: String
    let depth: Int
    let retainedBytes: Int64
    init(parent: ArchiveNavigationFrame, workspace: ArchiveWorkspace, memberPath: String, retainedBytes: Int64) {
        parentFrame = parent; self.workspace = workspace; self.memberPath = memberPath
        depth = parent.depth + 1; self.retainedBytes = retainedBytes
    }
}

public enum ArchiveNestedPasswordError: LocalizedError {
    case parent(ArchiveError), child(ArchiveError)
    public var errorDescription: String? {
        switch self { case .parent(let error), .child(let error): return error.errorDescription }
    }
}

/// Immutable navigation frames keep parent archives alive and never write back nested copies.
public final class ArchiveNavigationFrame: @unchecked Sendable {
    public static let maximumDepth = 4
    public static let maximumRetainedBytes: Int64 = 256 * 1024 * 1024
    public let snapshot: ArchiveSnapshot
    public let parent: ArchiveNavigationFrame?
    public let memberPath: String?
    public let depth: Int
    public let retainedBytes: Int64
    public var isReadOnly: Bool { snapshot.isReadOnly }
    public var displayPath: String {
        guard let parent, let memberPath else { return snapshot.sourceURL.path }
        return parent.displayPath + " !/" + memberPath
    }
    public init(snapshot: ArchiveSnapshot) {
        self.snapshot = snapshot
        parent = snapshot.context?.parentFrame; memberPath = snapshot.context?.memberPath
        depth = snapshot.context?.depth ?? 0; retainedBytes = snapshot.context?.retainedBytes ?? 0
    }
    private init(snapshot: ArchiveSnapshot, parent: ArchiveNavigationFrame, memberPath: String, retainedBytes: Int64) {
        self.snapshot = snapshot; self.parent = parent; self.memberPath = memberPath
        depth = parent.depth + 1; self.retainedBytes = retainedBytes
    }
    public func verifyCurrent() throws { try snapshot.verifyCurrent() }
    public func openNested(path: String, password: String? = nil, nestedPassword: String? = nil,
                           cancellation: TransferCancellation = TransferCancellation(),
                           onProgress: (ArchiveProgress) -> Void = { _ in },
                           observation: ArchiveReadObservation? = nil) throws -> ArchiveNavigationFrame {
        try verifyCurrent()
        guard depth < Self.maximumDepth else { throw ArchiveError.limitExceeded("глубина вложенных архивов") }
        guard let entry = snapshot.entries.first(where: { $0.path == path && !$0.isDirectory }) else {
            throw ArchiveError.invalidPath(path)
        }
        let maximum = min(Self.maximumRetainedBytes, snapshot.limits.maximumTotalBytes)
        guard retainedBytes <= maximum, entry.size <= maximum - retainedBytes else {
            throw ArchiveError.limitExceeded("размер рабочих копий вложенных архивов")
        }
        let workspace: ArchiveWorkspace
        do {
            workspace = try ArchiveReader.extract(snapshot, paths: [path], password: password,
                                                   cancellation: cancellation, onProgress: onProgress, observation: observation)
        } catch let error as ArchiveError where error == .passwordRequired || error == .incorrectPassword {
            throw ArchiveNestedPasswordError.parent(error)
        }
        return try openNested(workspace: workspace, path: path, nestedPassword: nestedPassword,
                              cancellation: cancellation, onProgress: onProgress, observation: observation)
    }
    func openNested(workspace: ArchiveWorkspace, path: String, nestedPassword: String? = nil,
                    cancellation: TransferCancellation, onProgress: (ArchiveProgress) -> Void,
                    observation: ArchiveReadObservation?) throws -> ArchiveNavigationFrame {
        try verifyCurrent()
        guard depth < Self.maximumDepth else { throw ArchiveError.limitExceeded("глубина вложенных архивов") }
        let maximum = min(Self.maximumRetainedBytes, snapshot.limits.maximumTotalBytes)
        guard retainedBytes <= maximum,
              let entry = snapshot.entries.first(where: { $0.path == path && !$0.isDirectory }),
              entry.size <= maximum - retainedBytes else {
            throw ArchiveError.limitExceeded("размер рабочих копий вложенных архивов")
        }
        var retained = false
        defer { if !retained { workspace.cleanup() } }
        let url = try workspace.url(for: path)
        let opened: ArchiveSnapshot
        do {
            opened = try ArchiveReader.open(url, password: nestedPassword, limits: snapshot.limits,
                                            cancellation: cancellation, onProgress: onProgress, observation: observation)
        } catch let error as ArchiveError where error == .passwordRequired || error == .incorrectPassword {
            throw ArchiveNestedPasswordError.child(error)
        }
        try verifyCurrent()
        // The source is immutable for the UI; the core writer also refuses its snapshot.
        guard chmod(url.path, 0o400) == 0 else { throw ArchiveError.io("Не удалось защитить вложенную рабочую копию.") }
        // chmod changes ctime: capture the final protected source version.
        let protected = try ArchiveReader.open(url, password: nestedPassword, limits: snapshot.limits,
                                               cancellation: cancellation, onProgress: onProgress, observation: observation)
        guard protected.entries == opened.entries, protected.format == opened.format else { throw ArchiveError.changedArchive }
        try verifyCurrent()
        try protected.verifyCurrent()
        if cancellation.isCancelled { throw ArchiveError.cancelled }
        let child = ArchiveSnapshot(sourceURL: protected.sourceURL, logicalSourcePath: protected.logicalSourcePath, entries: protected.entries, format: protected.format,
                                    limits: protected.limits, nestedReadOnly: true, stamp: protected.stamp,
                                    context: ArchiveSnapshotContext(parent: self, workspace: workspace, memberPath: path,
                                                                    retainedBytes: retainedBytes + entry.size))
        retained = true
        return ArchiveNavigationFrame(snapshot: child, parent: self, memberPath: path, retainedBytes: retainedBytes + entry.size)
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
                            onProgress: (ArchiveProgress) -> Void = { _ in },
                            observation: ArchiveReadObservation? = nil) throws -> ArchiveSnapshot {
        try checkLimits(limits)
        let source = try ArchiveInput(url: url, password: password, cancellation: cancellation)
        defer { source.close() }
        try validateZIPNames(source.fd, size: source.stamp.size, limits: limits, cancellation: cancellation)
        var entries: [ArchiveEntry] = []
        var topology = ArchivePath.Topology()
        var total: Int64 = 0
        var headers = 0
        while let entry = try source.next(cancellation: cancellation, observation: observation) {
            try observation?.header()
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
            try source.skip(cancellation: cancellation, expectedSize: archive_entry_size(entry), observation: archive_entry_is_encrypted(entry) > 0 && password == nil ? nil : observation)
        }
        let format = try source.format()
        try source.verify()
        return ArchiveSnapshot(sourceURL: url.standardizedFileURL, logicalSourcePath: SearchLocation.localKey(url), entries: entries, format: format,
                               limits: limits, nestedReadOnly: false, stamp: source.stamp, context: nil)
    }

    /// Validates the complete archive before creating any output. A nil selection extracts all files.
    /// A selected directory includes all descendants; extraction always stays in a new private workspace.
    public static func extract(_ snapshot: ArchiveSnapshot, paths: [String]? = nil, password: String? = nil,
                               cancellation: TransferCancellation = TransferCancellation(),
                               onProgress: (ArchiveProgress) -> Void = { _ in },
                               observation: ArchiveReadObservation? = nil) throws -> ArchiveWorkspace {
        try snapshot.verifyCurrent()
        try stopped(cancellation)
        let checked = try open(snapshot.sourceURL, password: password, limits: snapshot.limits, cancellation: cancellation, observation: observation)
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
        let source = try ArchiveInput(url: snapshot.sourceURL, password: password, cancellation: cancellation)
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
        while let raw = try source.next(cancellation: cancellation, observation: observation) {
            try observation?.header()
            guard let item = try decode(raw, limits: snapshot.limits) else { try source.skip(cancellation: cancellation, expectedSize: archive_entry_size(raw), observation: observation); continue }
            guard index < snapshot.entries.count, item == snapshot.entries[index] else { throw ArchiveError.changedArchive }
            index += 1
            guard selected(item.path) else { try source.skip(cancellation: cancellation, expectedSize: item.size, observation: observation); continue }
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
                    try observation?.bytes(Int64(count))
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

    /// One sequential pass serves metadata, recognition and selected working copies.
    /// Unselected compressed payloads are drained in bounded chunks for cancellation
    /// and shared search accounting; no member causes a repeated archive traversal.
    static func searchMembers(_ snapshot: ArchiveSnapshot, password: String?,
                              cancellation: TransferCancellation, observation: ArchiveReadObservation,
                              inspect: (ArchiveEntry) -> Bool,
                              materialize: (ArchiveEntry, Data) -> Bool,
                              consume: (ArchiveEntry, ArchiveWorkspace) -> Void) throws {
        try snapshot.verifyCurrent()
        let source = try ArchiveInput(url: snapshot.sourceURL, password: password, cancellation: cancellation)
        defer { source.close() }
        guard source.stamp == snapshot.stamp else { throw ArchiveError.changedArchive }
        var index = 0
        while let raw = try source.next(cancellation: cancellation, observation: observation) {
            try observation.header()
            guard let item = try decode(raw, limits: snapshot.limits) else {
                try source.skip(cancellation: cancellation, expectedSize: archive_entry_size(raw), observation: observation); continue
            }
            guard index < snapshot.entries.count, item == snapshot.entries[index] else { throw ArchiveError.changedArchive }
            index += 1
            guard inspect(item), !item.isDirectory else {
                try source.skip(cancellation: cancellation, expectedSize: item.size,
                                observation: item.isEncrypted && password == nil ? nil : observation); continue
            }
            var prefix = Data(count: Int(min(512, item.size)))
            var offset = 0
            while offset < prefix.count {
                try stopped(cancellation)
                let count = prefix.withUnsafeMutableBytes {
                    archive_read_data(source.archive, $0.baseAddress!.advanced(by: offset), $0.count - offset)
                }
                guard count > 0 else { throw source.failure() }
                try observation.bytes(Int64(count)); offset += count
            }
            guard materialize(item, prefix) else {
                try source.skip(cancellation: cancellation, expectedSize: item.size - Int64(prefix.count), observation: observation); continue
            }
            let workspace = try ArchiveWorkspace()
            // Ownership can pass into a nested snapshot in consume; otherwise ARC
            // releases the private directory immediately after this iteration.
            let parts = item.path.split(separator: "/").map(String.init)
            let root = Darwin.open(workspace.rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { throw ArchiveError.io("Не удалось открыть рабочую папку.") }
            defer { Darwin.close(root) }
            let parent = try secureDirectory(root: root, components: Array(parts.dropLast()))
            defer { Darwin.close(parent) }
            let output = openat(parent, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard output >= 0 else { throw ArchiveError.io("Не удалось создать рабочую копию: \(item.path)") }
            defer { Darwin.close(output) }
            func write(_ data: UnsafeRawBufferPointer) throws {
                var position = 0
                while position < data.count {
                    try stopped(cancellation)
                    let count = Darwin.write(output, data.baseAddress!.advanced(by: position), data.count - position)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ArchiveError.io("Не удалось записать рабочую копию.") }
                    position += count
                }
            }
            try prefix.withUnsafeBytes(write)
            var total = Int64(prefix.count)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try stopped(cancellation)
                let count = archive_read_data(source.archive, &buffer, buffer.count)
                guard count >= 0 else { throw source.failure() }
                if count == 0 { break }
                try observation.bytes(Int64(count)) // before any output write
                guard Int64(count) <= item.size - total else { throw ArchiveError.corruptArchive("Размер элемента не совпадает с заголовком.") }
                total += Int64(count)
                try buffer.withUnsafeBytes { try write(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            }
            guard total == item.size else { throw ArchiveError.corruptArchive("Неполные данные: \(item.path)") }
            try source.verify(); try snapshot.verifyCurrent()
            consume(item, workspace)
        }
        guard index == snapshot.entries.count else { throw ArchiveError.changedArchive }
        try source.verify(); try snapshot.verifyCurrent()
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
    /// cannot conceal a suffix. ZIP64 bounds are decoded before libarchive sees entries;
    /// multi-volume archives remain unsupported.
    private static func validateZIPNames(_ fd: Int32, size: Int64, limits: ArchiveLimits, cancellation: TransferCancellation) throws {
        guard size >= 4 else { return }
        func read(_ offset: Int64, _ count: Int) throws -> [UInt8] {
            guard offset >= 0, count >= 0, Int64(count) <= size, offset <= size - Int64(count) else {
                throw ArchiveError.corruptArchive("Структура ZIP выходит за границы файла.")
            }
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
        func u64(_ bytes: [UInt8], _ offset: Int) throws -> Int64 {
            let low = UInt64(u32(bytes, offset)), high = UInt64(u32(bytes, offset + 4))
            let value = low | high << 32
            guard value <= UInt64(Int64.max) else { throw ArchiveError.corruptArchive("Переполнение ZIP64.") }
            return Int64(value)
        }
        guard u16(tail, end + 4) == 0, u16(tail, end + 6) == 0,
              u16(tail, end + 8) == u16(tail, end + 10) else { throw ArchiveError.unsupportedFormat }
        let endOffset = size - Int64(count) + Int64(end)
        var entryCount = Int64(u16(tail, end + 10))
        var directorySize = u32(tail, end + 12), offset = u32(tail, end + 16)
        var directoryBoundary = endOffset
        let hasLocator = endOffset >= 20 ? try read(endOffset - 20, 4) == [0x50, 0x4b, 0x06, 0x07] : false
        if hasLocator {
            let locator = try read(endOffset - 20, 20)
            guard u32(locator, 4) == 0, u32(locator, 16) == 1 else { throw ArchiveError.unsupportedFormat }
            let recordOffset = try u64(locator, 8)
            let record = try read(recordOffset, 56)
            let recordSize = try u64(record, 4)
            guard Array(record[0..<4]) == [0x50, 0x4b, 0x06, 0x06], recordSize >= 44,
                  recordOffset <= endOffset - 20 - 12,
                  recordSize == endOffset - 20 - recordOffset - 12 else {
                throw ArchiveError.corruptArchive("Неверная структура ZIP64.")
            }
            guard u32(record, 16) == 0, u32(record, 20) == 0,
                  try u64(record, 24) == u64(record, 32) else { throw ArchiveError.unsupportedFormat }
            let fullCount = try u64(record, 32), fullSize = try u64(record, 40), fullOffset = try u64(record, 48)
            guard (entryCount == 65_535 || entryCount == fullCount),
                  (directorySize == 0xffff_ffff || directorySize == fullSize),
                  (offset == 0xffff_ffff || offset == fullOffset) else {
                throw ArchiveError.corruptArchive("Несогласованные каталоги ZIP64.")
            }
            entryCount = fullCount; directorySize = fullSize; offset = fullOffset; directoryBoundary = recordOffset
        } else if entryCount == 65_535 || directorySize == 0xffff_ffff || offset == 0xffff_ffff {
            throw ArchiveError.corruptArchive("Отсутствует каталог ZIP64.")
        }
        guard entryCount <= Int64(limits.maximumEntries) else { throw ArchiveError.limitExceeded("число элементов") }
        guard offset <= directoryBoundary, directorySize <= directoryBoundary - offset else {
            throw ArchiveError.corruptArchive("Неверный каталог ZIP.")
        }
        let directoryStart = offset
        let directoryEnd = offset + directorySize
        for _ in 0..<Int(entryCount) {
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
            guard u16(header, 34) == 0 else { throw ArchiveError.unsupportedFormat }
            var uncompressedSize = u32(header, 24), compressedSize = u32(header, 20), localOffset = u32(header, 42)
            let requiresZIP64 = uncompressedSize == 0xffff_ffff || compressedSize == 0xffff_ffff || localOffset == 0xffff_ffff
            var foundZIP64 = false
            var extraOffset = 0
            while extraOffset + 4 <= extra.count {
                let identifier = u16(extra, extraOffset)
                let fieldLength = u16(extra, extraOffset + 2)
                guard extraOffset + 4 + fieldLength <= extra.count else {
                    throw ArchiveError.corruptArchive("Неполные дополнительные данные ZIP.")
                }
                if identifier == 0x0001 {
                    guard !foundZIP64 else { throw ArchiveError.corruptArchive("Повторное поле ZIP64.") }
                    foundZIP64 = true
                    var cursor = extraOffset + 4
                    let fieldEnd = cursor + fieldLength
                    func next64() throws -> Int64 {
                        guard cursor + 8 <= fieldEnd else { throw ArchiveError.corruptArchive("Неполное поле ZIP64.") }
                        defer { cursor += 8 }
                        return try u64(extra, cursor)
                    }
                    if uncompressedSize == 0xffff_ffff { uncompressedSize = try next64() }
                    if compressedSize == 0xffff_ffff { compressedSize = try next64() }
                    if localOffset == 0xffff_ffff { localOffset = try next64() }
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
            guard extraOffset == extra.count, !requiresZIP64 || foundZIP64 else {
                throw ArchiveError.corruptArchive("Неверные дополнительные данные ZIP.")
            }
            guard uncompressedSize <= limits.maximumEntryBytes else { throw ArchiveError.limitExceeded("размер элемента ZIP") }
            guard localOffset < directoryStart, localOffset <= directoryStart - 30 else { throw ArchiveError.corruptArchive("Неверный адрес ZIP.") }
            let local = try read(localOffset, 30)
            guard Array(local[0..<4]) == [0x50, 0x4b, 0x03, 0x04] else { throw ArchiveError.corruptArchive("Неверный локальный заголовок ZIP.") }
            let dataOffset = localOffset + 30 + Int64(u16(local, 26) + u16(local, 28))
            guard dataOffset <= directoryStart, compressedSize <= directoryStart - dataOffset else {
                throw ArchiveError.corruptArchive("Данные ZIP выходят за границы файла.")
            }
            let localName = try read(localOffset + 30, u16(local, 26))
            guard localName == name else { throw ArchiveError.corruptArchive("Локальное имя ZIP не совпадает с каталогом.") }
            offset += Int64(length)
        }
        guard offset == directoryEnd else { throw ArchiveError.corruptArchive("Размер каталога ZIP не совпадает.") }
    }
}

fileprivate struct ArchiveStamp: Codable, Sendable, Equatable {
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
    init(url: URL, password: String?, cancellation: TransferCancellation) throws {
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
        do { try ArchiveCompression.prepare(archive, fd: fd, size: stamp.size, cancellation: cancellation) }
        catch { close(); throw error }
        // libarchive 3.7.4's seekable-only bidder does not recognize the valid
        // 22-byte empty ZIP. Register both ZIP readers so that case can use
        // the streamable reader; our central-directory preflight still runs
        // before any entry is exposed or extracted.
        archive_read_support_format_zip(archive)
        archive_read_support_format_tar(archive)
        // AppleDouble processing otherwise consumes and copies arbitrary metadata
        // inside next_header, before our size checks and read observers can run.
        // Preserve these members as ordinary, explicitly bounded archive files.
        guard archive_read_set_format_option(archive, "tar", "mac-ext", nil) == ARCHIVE_OK,
              archive_read_set_format_option(archive, "zip", "mac-ext", nil) == ARCHIVE_OK else {
            close(); throw ArchiveError.unsupportedFormat
        }
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
    func next(cancellation: TransferCancellation, observation: ArchiveReadObservation? = nil) throws -> OpaquePointer? {
        if cancellation.isCancelled { throw ArchiveError.cancelled }
        // libarchive consumes PAX/GNU metadata internally before returning the
        // public member. Account those bytes as well as ordinary member payloads.
        // Native PAX/long-name chains are bounded by libarchive; cancellation and
        // shared-budget checks resume after the native call, before a member is
        // emitted or written. AppleDouble interpretation is disabled above.
        let before = archive_filter_bytes(archive, 0)
        var entry: OpaquePointer?
        let result = archive_read_next_header(archive, &entry)
        let after = archive_filter_bytes(archive, 0)
        if after > before { try observation?.bytes(after - before) }
        if cancellation.isCancelled { throw ArchiveError.cancelled }
        if result == ARCHIVE_EOF { return nil }
        guard result == ARCHIVE_OK, let entry else { throw failure() }
        _ = try format()
        return entry
    }
    func skip(cancellation: TransferCancellation, expectedSize: Int64,
              observation: ArchiveReadObservation?) throws {
        guard let observation else {
            guard archive_read_data_skip(archive) == ARCHIVE_OK else { throw failure() }
            return
        }
        // Search must be interruptible while a compressed TAR member is skipped.
        // A forged size cannot cause an unbounded decode outside the shared budget.
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total: Int64 = 0
        while true {
            if cancellation.isCancelled { throw ArchiveError.cancelled }
            let count = archive_read_data(archive, &buffer, buffer.count)
            guard count >= 0 else { throw failure() }
            if count == 0 { break }
            try observation.bytes(Int64(count))
            guard Int64(count) <= max(0, expectedSize) - total else {
                throw ArchiveError.corruptArchive("Размер элемента не совпадает с заголовком.")
            }
            total += Int64(count)
        }
    }
    func format() throws -> ArchiveFormat {
        // A single explicitly supported compression layer plus the source filter.
        // Reject stacked filters and compressed ZIP even if the library can decode them.
        let filters = archive_filter_count(archive)
        let filter = archive_filter_code(archive, 0)
        guard filters == 1 || (filters == 2 && archive_filter_code(archive, 1) == ARCHIVE_FILTER_NONE) else {
            throw ArchiveError.unsupportedFormat
        }
        switch archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK {
        case ARCHIVE_FORMAT_ZIP:
            guard hasZIPStart, filter == ARCHIVE_FILTER_NONE else { throw ArchiveError.unsupportedFormat }
            return .zip
        case ARCHIVE_FORMAT_TAR:
            switch filter {
            case ARCHIVE_FILTER_NONE: return .tar
            case ARCHIVE_FILTER_GZIP: return .tarGzip
            case ARCHIVE_FILTER_BZIP2: return .tarBzip2
            case ARCHIVE_FILTER_XZ: return .tarXz
            default: throw ArchiveError.unsupportedFormat
            }
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
