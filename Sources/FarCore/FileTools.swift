import Foundation
import Darwin

public struct FileToolItem: Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let permissions: UInt16
    public let modified: Date
    public let accessed: Date
    public let created: Date
    public let flags: UInt32
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
    fileprivate let mode: mode_t
}

public struct BatchRenameEntry: Sendable {
    public let source: FileToolItem
    public let destination: URL
}

public final class FileToolCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public struct DirectorySizeResult: Sendable {
    public fileprivate(set) var bytes: Int64 = 0
    public fileprivate(set) var files = 0
    public fileprivate(set) var directories = 0
    public fileprivate(set) var symbolicLinks = 0
    public fileprivate(set) var unreadable = 0
    public fileprivate(set) var isCancelled = false
    public init() {}
}

public enum FileTools {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Captures the selected directory entries, preserving a final symbolic link.
    /// Operations reject a replaced source and a selection containing parent + child.
    public static func snapshot(_ urls: [URL]) throws -> [FileToolItem] {
        var paths = Set<String>()
        let items = try urls.map { url -> FileToolItem in
            guard url.isFileURL else { throw Failure("Поддерживаются только локальные файлы.") }
            let normalized = url.standardizedFileURL
            guard normalized.path != "/" else { throw Failure("Операция над корнем файловой системы запрещена.") }
            let canonical = normalized.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(normalized.lastPathComponent)
            guard paths.insert(canonical.path).inserted else { throw Failure("Объект выбран несколько раз: \(canonical.path)") }
            var info = stat()
            guard lstat(canonical.path, &info) == 0 else { throw posix("Прочитать", canonical) }
            return item(canonical, info)
        }
        for parent in items where parent.isDirectory {
            guard !items.contains(where: { $0.url.path.hasPrefix(parent.url.path + "/") }) else {
                throw Failure("Выбраны папка и вложенный объект. Выполните операции отдельно.")
            }
        }
        return items
    }

    /// Builds a reviewed plan using either the literal {name}/{ext}/{n} template
    /// or FAR's destination-name wildcard conversion. Neither mode changes folders.
    public static func renamePlan(_ urls: [URL], template: String, mode: BatchRenameMode = .template) throws -> [BatchRenameEntry] {
        let items = try snapshot(urls)
        guard !items.isEmpty else { throw Failure("Нет выбранных объектов.") }
        let remainder = template.replacingOccurrences(of: "{name}", with: "")
            .replacingOccurrences(of: "{ext}", with: "").replacingOccurrences(of: "{n}", with: "")
        guard mode != .template || (!remainder.contains("{") && !remainder.contains("}")) else {
            throw Failure("Допустимы только подстановки {name}, {ext}, {n}.")
        }
        let mask = mode == .farMask ? try FilenameRenameMask(template) : nil
        let plan = try items.enumerated().map { index, source -> BatchRenameEntry in
            let ext = source.isDirectory ? "" : source.url.pathExtension
            let stem = ext.isEmpty ? source.url.lastPathComponent : source.url.deletingPathExtension().lastPathComponent
            // Split the original template so braces in filenames are never expanded again.
            let name = try mask?.destinationName(for: source.url.lastPathComponent) ?? template.components(separatedBy: "{name}").map {
                $0.components(separatedBy: "{ext}").map {
                    $0.replacingOccurrences(of: "{n}", with: String(index + 1))
                }.joined(separator: ext)
            }.joined(separator: stem)
            try validateName(name)
            return BatchRenameEntry(source: source, destination: source.url.deletingLastPathComponent().appendingPathComponent(name))
        }
        try validateRename(plan)
        return plan
    }

    /// Revalidates the reviewed plan. Exclusive rename prevents racing writers from
    /// being overwritten. On failure, completed renames remain and are reported.
    @discardableResult
    public static func executeRename(_ plan: [BatchRenameEntry], propagateDescriptions: Bool = true,
                                     descriptionEncodings: [String: FileDescriptionEncoding] = [:],
                                     allowCaseOnly: Bool = false) throws -> Int {
        try validateRename(plan, allowCaseOnly: allowCaseOnly)
        let groups = Dictionary(grouping: plan, by: { FileDescriptionEncoding.directoryKey($0.source.url.deletingLastPathComponent()) })
        var descriptions = [String: FileDescriptionRenamePlan]()
        if propagateDescriptions {
            for (key, entries) in groups {
                // An explicitly selected control file is ordinary user data; do not
                // concurrently rewrite that same file as automatic metadata.
                guard !entries.contains(where: { $0.source.url.lastPathComponent == "descript.ion" || $0.destination.lastPathComponent == "descript.ion" }) else { continue }
                descriptions[key] = try FileDescriptionRenamePlan.prepare(directory: entries[0].source.url.deletingLastPathComponent(), encoding: descriptionEncodings[key] ?? .utf8)
            }
        }
        var completed = [BatchRenameEntry](), operationError: Error?
        for entry in plan {
            do {
                try verify(entry.source)
                guard renameatx_np(AT_FDCWD, entry.source.url.path, AT_FDCWD, entry.destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw posix("Переименовать", entry.source.url)
                }
                completed.append(entry)
            } catch { operationError = error; break }
        }
        var warnings = [String]()
        for (key, entries) in Dictionary(grouping: completed, by: { FileDescriptionEncoding.directoryKey($0.source.url.deletingLastPathComponent()) }) {
            do { try descriptions[key]?.apply(completedRenames: entries.map { (source: $0.source.url.lastPathComponent, destination: $0.destination.lastPathComponent) }) }
            catch { warnings.append("Описания в «\(key)» не обновлены: \(error.localizedDescription)") }
        }
        if let operationError { warnings.insert(operationError.localizedDescription, at: 0) }
        if !warnings.isEmpty { throw partial(Failure(warnings.joined(separator: "\n")), completed.count, plan.count) }
        return completed.count
    }

    public static func metadata(_ url: URL) throws -> FileToolItem {
        guard let value = try snapshot([url]).first else { throw Failure("Нет объекта.") }
        return value
    }

    public static func parsePermissions(_ octal: String) throws -> UInt16 {
        guard (3...4).contains(octal.count), octal.utf8.allSatisfy({ (48...55).contains($0) }),
              let value = UInt16(octal, radix: 8), value <= 0o7777 else {
            throw Failure("Права: 3–4 восьмеричные цифры от 000 до 7777.")
        }
        return value
    }

    /// Opens without following the selected link and edits the verified descriptor.
    /// Special files and symbolic links are intentionally read-only here.
    public static func setPermissions(_ octal: String, for source: FileToolItem) throws {
        let permissions = try parsePermissions(octal)
        guard source.mode & S_IFMT == S_IFREG || source.isDirectory else {
            throw Failure("Изменение прав ссылок и специальных файлов не поддерживается.")
        }
        let fd = open(source.url.path, O_EVTONLY | O_NONBLOCK | O_NOFOLLOW)
        if fd >= 0 {
            defer { Darwin.close(fd) }
            var current = stat()
            guard fstat(fd, &current) == 0, matches(source, current) else { throw Failure("Объект изменён после открытия окна. Откройте свойства заново.") }
            guard fchmod(fd, mode_t(permissions)) == 0 else { throw posix("Изменить права", source.url) }
            return
        }
        // An owner may chmod an unreadable mode-000 object, while even O_EVTONLY
        // can require read access. Anchor its parent and use no-follow chmod here:
        // a concurrently substituted symlink can never change its target's mode.
        guard errno == EACCES else { throw posix("Открыть для изменения прав", source.url) }
        let parent = open(source.url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw posix("Открыть родительскую папку", source.url) }
        defer { Darwin.close(parent) }
        var current = stat()
        let name = source.url.lastPathComponent
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, matches(source, current) else { throw Failure("Объект заменён. Откройте свойства заново.") }
        guard fchmodat(parent, name, mode_t(permissions), AT_SYMLINK_NOFOLLOW) == 0 else { throw posix("Изменить права", source.url) }
    }

    public static func createLink(source: FileToolItem, at destination: URL, symbolic: Bool) throws {
        guard destination.isFileURL else { throw Failure("Поддерживаются только локальные файлы.") }
        try validateName(destination.lastPathComponent)
        try verify(source)
        if !symbolic && (source.isDirectory || source.isSymbolicLink || source.mode & S_IFMT != S_IFREG) {
            throw Failure("Жёсткую ссылку можно создать только на обычный файл.")
        }
        let result = symbolic ? symlink(source.url.path, destination.path) : link(source.url.path, destination.path)
        guard result == 0 else { throw posix("Создать ссылку (назначение должно отсутствовать)", destination) }
    }

    /// Permanent, irreversible removal. Caller must obtain explicit confirmation for
    /// these exact snapshots. Recursion uses directory descriptors and never follows
    /// symbolic links. Cancellation or error may leave a partially removed directory.
    @discardableResult
    public static func permanentlyDelete(_ items: [FileToolItem], cancellation: FileToolCancellation = FileToolCancellation()) throws -> Int {
        _ = try snapshot(items.map(\.url)) // reject roots, duplicate/overlapping selections
        for source in items { try verify(source) }
        var completed = 0
        for source in items {
            do {
                if cancellation.isCancelled { throw Failure("Удаление отменено.") }
                let parent = open(source.url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard parent >= 0 else { throw posix("Открыть родительскую папку", source.url) }
                defer { Darwin.close(parent) }
                var info = stat()
                guard fstatat(parent, source.url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0, matches(source, info) else {
                    throw Failure("Источник изменён: \(source.url.path)")
                }
                try remove(parent: parent, name: source.url.lastPathComponent, expected: info, cancellation: cancellation)
                completed += 1
            } catch { throw partial(error, completed, items.count) }
        }
        return completed
    }

    /// Logical bytes of regular files; symlinks are counted but never traversed.
    /// Inaccessible entries are reported rather than silently treated as zero.
    public static func directorySize(_ url: URL, cancellation: FileToolCancellation = FileToolCancellation()) throws -> DirectorySizeResult {
        let source = try metadata(url)
        guard source.isDirectory else { throw Failure("Выберите папку, а не символическую ссылку.") }
        var result = DirectorySizeResult()
        if cancellation.isCancelled { result.isCancelled = true; return result }
        let fd = open(source.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw posix("Открыть папку", source.url) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, matches(source, info) else { throw Failure("Папка изменена до начала подсчёта.") }
        size(fd, cancellation: cancellation, result: &result)
        result.isCancelled = cancellation.isCancelled
        return result
    }

    private static func size(_ fd: Int32, cancellation: FileToolCancellation, result: inout DirectorySizeResult) {
        do {
            try children(fd) { name in
                if cancellation.isCancelled { throw Failure("Отменено") }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { result.unreadable += 1; return }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    result.directories += 1
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard child >= 0 else { result.unreadable += 1; return }
                    defer { Darwin.close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { result.unreadable += 1; return }
                    size(child, cancellation: cancellation, result: &result)
                case S_IFLNK: result.symbolicLinks += 1
                case S_IFREG: result.files += 1; result.bytes += Int64(info.st_size)
                default: break
                }
            }
        } catch { if !cancellation.isCancelled { result.unreadable += 1 } }
    }

    private static func remove(parent: Int32, name: String, expected: stat, cancellation: FileToolCancellation) throws {
        if cancellation.isCancelled { throw Failure("Удаление отменено; папка могла быть удалена частично.") }
        if expected.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw Failure("Не удалось открыть папку: \(name): \(String(cString: strerror(errno)))") }
            defer { Darwin.close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_dev == expected.st_dev, opened.st_ino == expected.st_ino else { throw Failure("Папка заменена: \(name)") }
            try children(fd) { child in
                var info = stat()
                guard fstatat(fd, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure("Не удалось проверить объект: \(child)") }
                try remove(parent: fd, name: child, expected: info, cancellation: cancellation)
            }
        }
        if cancellation.isCancelled { throw Failure("Удаление отменено; папка могла быть удалена частично.") }
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == expected.st_dev, current.st_ino == expected.st_ino else { throw Failure("Объект заменён: \(name)") }
        guard unlinkat(parent, name, expected.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
            throw Failure("Не удалось удалить \(name): \(String(cString: strerror(errno)))")
        }
    }

    private static func children(_ fd: Int32, body: (String) throws -> Void) throws {
        let copy = dup(fd)
        guard copy >= 0 else { throw Failure("Не удалось открыть список папки.") }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw Failure("Не удалось прочитать папку.") }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Failure("Ошибка чтения папки: \(String(cString: strerror(errno)))") }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .utf8)
            }
            guard let name else { throw Failure("Имя объекта не является UTF-8; обработка остановлена.") }
            if name != "." && name != ".." { try body(name) }
        }
    }

    static func validateRename(_ plan: [BatchRenameEntry], allowCaseOnly: Bool = false) throws {
        _ = try snapshot(plan.map { $0.source.url })
        var names = Set<String>()
        var storedNames: [String: Set<Data>] = [:]
        let sources = Set(plan.map { $0.source.url.path })
        for entry in plan {
            try verify(entry.source)
            let parent = entry.destination.deletingLastPathComponent()
            let oldName = entry.source.url.lastPathComponent, newName = entry.destination.lastPathComponent
            try validateName(newName)
            guard parent == entry.source.url.deletingLastPathComponent() else { throw Failure("Переименование не может менять папку.") }
            let sensitivity = (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames
            let path = entry.destination.path.precomposedStringWithCanonicalMapping
            let key = sensitivity == true ? path : path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(key).inserted else { throw Failure("Несколько объектов получают одинаковое имя.") }
            guard !sources.contains(entry.destination.path) else { throw Failure("Назначение совпадает с выбранным источником. Циклы и неизменённые имена запрещены.") }
            var info = stat()
            if lstat(entry.destination.path, &info) == 0 {
                let conflict = Failure("Назначение уже существует: \(newName). Перезапись запрещена.")
                guard allowCaseOnly, sensitivity == false, oldName.caseInsensitiveCompare(newName) == .orderedSame,
                      matches(entry.source, info) else { throw conflict }
                // Same inode is insufficient because another directory entry
                // may be a hard link to it. Check the actual stored names.
                if storedNames[parent.path] == nil {
                    storedNames[parent.path] = Set(try FileManager.default.contentsOfDirectory(atPath: parent.path).map { Data($0.utf8) })
                }
                guard let spelling = storedNames[parent.path], spelling.contains(Data(oldName.utf8)),
                      !spelling.contains(Data(newName.utf8)) else { throw conflict }
            } else if errno != ENOENT {
                throw posix("Проверить назначение", entry.destination)
            }
        }
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw Failure("Недопустимое имя файла.") }
    }
    /// Confirms that the selected directory entry still has the captured identity.
    public static func verify(_ source: FileToolItem) throws {
        var info = stat()
        guard lstat(source.url.path, &info) == 0, matches(source, info) else { throw Failure("Источник исчез или был заменён: \(source.url.path)") }
    }
    private static func matches(_ source: FileToolItem, _ info: stat) -> Bool {
        source.device == info.st_dev && source.inode == info.st_ino && source.mode & S_IFMT == info.st_mode & S_IFMT
    }
    private static func item(_ url: URL, _ info: stat) -> FileToolItem {
        FileToolItem(url: url, isDirectory: info.st_mode & S_IFMT == S_IFDIR,
                     isSymbolicLink: info.st_mode & S_IFMT == S_IFLNK, size: Int64(info.st_size),
                     permissions: UInt16(info.st_mode & 0o7777),
                     modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
                     accessed: Date(timeIntervalSince1970: Double(info.st_atimespec.tv_sec) + Double(info.st_atimespec.tv_nsec) / 1e9),
                     created: Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9),
                     flags: info.st_flags,
                     device: info.st_dev, inode: info.st_ino, mode: info.st_mode)
    }
    private static func posix(_ action: String, _ url: URL) -> Failure {
        Failure("\(action) «\(url.path)»: \(String(cString: strerror(errno)))")
    }
    private static func partial(_ error: Error, _ completed: Int, _ total: Int) -> Failure {
        Failure("\(error.localizedDescription) Завершено объектов: \(completed) из \(total). Изменения не откатывались; текущий объект мог быть обработан частично.")
    }
}
