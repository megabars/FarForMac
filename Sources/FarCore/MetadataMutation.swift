import Foundation
import Darwin

public struct MetadataChanges: Equatable, Sendable {
    public var permissions: UInt16?
    public var accessed: Date?
    public var modified: Date?
    public var groupID: UInt32?
    public init(permissions: UInt16? = nil, accessed: Date? = nil, modified: Date? = nil, groupID: UInt32? = nil) {
        self.permissions = permissions; self.accessed = accessed; self.modified = modified; self.groupID = groupID
    }
    fileprivate func validate() throws {
        guard permissions != nil || accessed != nil || modified != nil || groupID != nil,
              permissions.map({ $0 <= 0o7777 }) ?? true else { throw MetadataMutation.Error("Выберите корректные изменения свойств.") }
        if let groupID {
            guard try MetadataOwnership.availableGroups().contains(where: { $0.id == groupID }) else {
                throw MetadataMutation.Error("Можно выбрать только группу текущего пользователя.")
            }
        }
        for date in [accessed, modified].compactMap({ $0 }) {
            guard date.timeIntervalSince1970.isFinite, (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970) else {
                throw MetadataMutation.Error("Дата должна находиться между 1 и 9999 годом.")
            }
        }
    }
}

public struct MetadataMutationEntry: Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let previousPermissions: UInt16
    public let hardLinkCount: Int
    public let previousOwnerID: UInt32
    public let previousGroupID: UInt32
    public let previousAccessed: Date
    public let previousModified: Date
    fileprivate let components: [String]
    fileprivate let stamp: MetadataStamp
}
public struct MetadataMutationPlan: Sendable {
    public let entries: [MetadataMutationEntry]
    public let changes: MetadataChanges
    public let recursive: Bool
    public let skippedSymbolicLinks: Int
    public let skippedSpecialFiles: Int
    public let skippedOtherVolumes: Int
    public let skippedDuplicateHardLinks: Int
    fileprivate let root: URL
    fileprivate let rootStamp: MetadataStamp
}
public struct MetadataMutationReport: Sendable {
    public fileprivate(set) var completed = 0
    public let total: Int
    public fileprivate(set) var isCancelled = false
    public fileprivate(set) var error: String?
}

fileprivate struct MetadataStamp: Sendable {
    let device: dev_t
    let inode: ino_t
    let kind: mode_t
    let permissions: UInt16
    let owner: uid_t
    let group: gid_t
    let size: off_t
    let links: nlink_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; kind = info.st_mode & S_IFMT
        permissions = UInt16(info.st_mode & 0o7777)
        owner = info.st_uid; group = info.st_gid; size = info.st_size; links = info.st_nlink
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
    }
    func matches(_ info: stat) -> Bool {
        device == info.st_dev && inode == info.st_ino && kind == info.st_mode & S_IFMT &&
        permissions == UInt16(info.st_mode & 0o7777) && modifiedSeconds == info.st_mtimespec.tv_sec && modifiedNanos == info.st_mtimespec.tv_nsec
        && owner == info.st_uid && group == info.st_gid && size == info.st_size && links == info.st_nlink
        && changedSeconds == info.st_ctimespec.tv_sec && changedNanos == info.st_ctimespec.tv_nsec
    }
}

/// Reviewed local metadata changes. No link traversal, ACL editing or privilege escalation.
public enum MetadataMutation {
    public struct Error: LocalizedError {
        public let errorDescription: String?
        fileprivate init(_ message: String) { errorDescription = message }
    }
    public static let maximumEntries = 100_000
    public static let maximumDepth = 128

    /// Reads the complete plan without mutations. Every selected field applies to every
    /// reviewed entry. Directories are ordered after children.
    public static func prepare(url: URL, changes: MetadataChanges, recursive: Bool = false,
                               cancellation: FileToolCancellation = FileToolCancellation()) throws -> MetadataMutationPlan {
        try changes.validate()
        let root = try FileTools.metadata(url).url
        let parent = try openDirectory(root.deletingLastPathComponent())
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, root.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw system("Прочитать", root) }
        let rootStamp = MetadataStamp(info)
        guard rootStamp.kind == S_IFREG || rootStamp.kind == S_IFDIR else { throw Error("Ссылки и специальные файлы доступны только для чтения.") }
        var entries: [MetadataMutationEntry] = [], links = 0, special = 0, volumes = 0, duplicates = 0
        var visited = Set<String>(), inspected = 0
        func visit(parent: Int32, name: String, components: [String], info: stat) throws {
            guard !cancellation.isCancelled else { throw Error("Подготовка отменена. Изменений нет.") }
            inspected += 1
            guard inspected <= maximumEntries, components.count <= maximumDepth else { throw Error("Превышен предел: 100000 объектов или 128 уровней. Изменений нет.") }
            let path = components.reduce(root) { $0.appendingPathComponent($1) }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK { links += 1; return }
            guard kind == S_IFREG || kind == S_IFDIR else { special += 1; return }
            if info.st_dev != rootStamp.device { volumes += 1; return }
            if changes.groupID != nil, info.st_uid != geteuid() {
                throw Error("Группу можно менять только у объектов текущего пользователя: \(path.path)")
            }
            let identity = "\(info.st_dev):\(info.st_ino)"
            if !visited.insert(identity).inserted { duplicates += 1; return }
            let fd = openat(parent, name, (kind == S_IFDIR && recursive ? O_RDONLY | O_DIRECTORY : O_EVTONLY) | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
            guard fd >= 0 else { throw system("Открыть без обхода ссылок", path) }
            defer { close(fd) }
            var opened = stat()
            let stamp = MetadataStamp(info)
            guard fstat(fd, &opened) == 0, stamp.matches(opened) else { throw Error("Объект изменился: \(path.path)") }
            if recursive && kind == S_IFDIR {
                try children(fd) { child in
                    var value = stat()
                    guard fstatat(fd, child, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw system("Прочитать", path.appendingPathComponent(child)) }
                    try visit(parent: fd, name: child, components: components + [child], info: value)
                }
            }
            entries.append(MetadataMutationEntry(url: path, isDirectory: kind == S_IFDIR,
                previousPermissions: UInt16(info.st_mode & 0o7777), hardLinkCount: Int(info.st_nlink),
                previousOwnerID: info.st_uid, previousGroupID: info.st_gid,
                previousAccessed: date(info.st_atimespec), previousModified: date(info.st_mtimespec),
                components: components, stamp: stamp))
        }
        try visit(parent: parent, name: root.lastPathComponent, components: [], info: info)
        return MetadataMutationPlan(entries: entries, changes: changes, recursive: recursive,
            skippedSymbolicLinks: links, skippedSpecialFiles: special, skippedOtherVolumes: volumes,
            skippedDuplicateHardLinks: duplicates, root: root, rootStamp: rootStamp)
    }

    /// Revalidates every reviewed entry before changing any, then verifies each
    /// descriptor again. Stops at first error; completed changes are not rolled back.
    public static func apply(_ plan: MetadataMutationPlan, cancellation: FileToolCancellation = FileToolCancellation(),
                             progress: (Int, Int, String) -> Void = { _, _, _ in }) -> MetadataMutationReport {
        var report = MetadataMutationReport(total: plan.entries.count)
        var mutationStarted = false
        do {
            try plan.changes.validate()
            if cancellation.isCancelled { report.isCancelled = true; return report }
            let parent = try openDirectory(plan.root.deletingLastPathComponent())
            defer { close(parent) }
            let root = openat(parent, plan.root.lastPathComponent, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard root >= 0 else { throw system("Открыть выбранный объект", plan.root) }
            defer { close(root) }
            var rootInfo = stat()
            guard fstat(root, &rootInfo) == 0, plan.rootStamp.matches(rootInfo) else { throw Error("Выбранный объект изменён после предпросмотра. Изменений нет.") }
            func openEntry(_ entry: MetadataMutationEntry) throws -> Int32 {
                if entry.components.isEmpty {
                    let copy = dup(root); guard copy >= 0 else { throw system("Открыть объект", entry.url) }; return copy
                }
                var anchor = dup(root)
                guard anchor >= 0 else { throw system("Открыть папку", plan.root) }
                defer { close(anchor) }
                for component in entry.components.dropLast() {
                    let child = openat(anchor, component, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    guard child >= 0 else { throw system("Проверить путь", entry.url) }
                    close(anchor); anchor = child
                }
                let descriptor = openat(anchor, entry.components.last!, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard descriptor >= 0 else { throw system("Открыть объект", entry.url) }
                return descriptor
            }
            func verify(_ fd: Int32, _ entry: MetadataMutationEntry) throws {
                var info = stat()
                guard fstat(fd, &info) == 0, entry.stamp.matches(info) else { throw Error("Объект заменён или изменён после предпросмотра: \(entry.url.path)") }
                if plan.changes.groupID != nil, info.st_uid != geteuid() { throw Error("Владелец объекта не совпадает с текущим пользователем: \(entry.url.path)") }
            }
            for entry in plan.entries {
                if cancellation.isCancelled { report.isCancelled = true; return report }
                let fd = try openEntry(entry); defer { close(fd) }; try verify(fd, entry)
            }
            for entry in plan.entries {
                if cancellation.isCancelled { report.isCancelled = true; return report }
                let fd = try openEntry(entry); defer { close(fd) }; try verify(fd, entry)
                mutationStarted = true
                if let groupID = plan.changes.groupID, groupID != entry.previousGroupID {
                    // chown may clear set-ID bits. A group-only edit never silently
                    // restores executable privilege bits; the UI warns explicitly.
                    guard fchown(fd, uid_t.max, gid_t(groupID)) == 0 else { throw system("Изменить группу", entry.url) }
                }
                if plan.changes.accessed != nil || plan.changes.modified != nil {
                    var times = [timestamp(plan.changes.accessed), timestamp(plan.changes.modified)]
                    guard futimens(fd, &times) == 0 else { throw system("Изменить даты", entry.url) }
                }
                if let permissions = plan.changes.permissions {
                    guard fchmod(fd, mode_t(permissions)) == 0 else { throw system("Изменить права", entry.url) }
                }
                report.completed += 1
                progress(report.completed, report.total, entry.url.path)
            }
        } catch { report.error = error.localizedDescription + (mutationStarted ? " Текущий объект мог измениться частично; отката нет." : " Изменений нет.") }
        return report
    }
    private static func date(_ timestamp: timespec) -> Date {
        Date(timeIntervalSince1970: Double(timestamp.tv_sec) + Double(timestamp.tv_nsec) / 1e9)
    }
    private static func timestamp(_ date: Date?) -> timespec {
        guard let date else { return timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)) }
        let value = date.timeIntervalSince1970, seconds = floor(value)
        return timespec(tv_sec: Int(seconds), tv_nsec: min(999_999_999, max(0, Int((value - seconds) * 1e9))))
    }
    /// Resolves the parent to its POSIX path, then rejects link substitutions
    /// during the component walk. Root and entry identity are checked separately.
    private static func openDirectory(_ url: URL) throws -> Int32 {
        // Foundation deliberately presents /private/var as /var on macOS. Use
        // POSIX realpath for the actual component walk; /var itself is a symlink.
        guard let resolved = realpath(url.path, nil) else { throw system("Найти родительскую папку", url) }
        let path = String(cString: resolved); free(resolved)
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw system("Открыть корень", url) }
        do {
            for component in path.split(separator: "/") {
                let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard next >= 0 else { throw system("Открыть родительскую папку без ссылок", url) }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func children(_ fd: Int32, body: (String) throws -> Void) throws {
        let copy = dup(fd)
        guard copy >= 0 else { throw Error("Не удалось открыть список папки.") }
        guard let stream = fdopendir(copy) else { close(copy); throw Error("Не удалось прочитать папку.") }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Error("Ошибка чтения папки: \(String(cString: strerror(errno)))") }
                return
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8) }
            guard let name else { throw Error("Имя файла не является UTF-8; подготовка остановлена.") }
            if name != "." && name != ".." { try body(name) }
        }
    }
    private static func system(_ action: String, _ url: URL) -> Error { Error("\(action) «\(url.path)»: \(String(cString: strerror(errno)))") }
}
