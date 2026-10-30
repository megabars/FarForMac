import Foundation
import Darwin

public struct DirectoryComparisonOptions: Sendable {
    public var compareContents = false
    public var caseSensitiveNames = false
    public var includeHidden = true
    public var maximumEntriesPerDirectory = 10_000
    public var maximumContentBytesPerFile: Int64 = 64 * 1_024 * 1_024
    public var maximumTotalContentBytes: Int64 = 512 * 1_024 * 1_024
    public init() {}
}

public final class DirectoryComparisonCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public enum DirectoryComparisonStatus: String, Sendable {
    case same, leftOnly, rightOnly, leftNewer, rightNewer, different
    case directorySkipped, symbolicLinkSkipped, typeConflict, ambiguousName, unsupported, error
    public var description: String {
        switch self {
        case .same: return "Совпадает"
        case .leftOnly: return "Только слева"
        case .rightOnly: return "Только справа"
        case .leftNewer: return "Слева новее"
        case .rightNewer: return "Справа новее"
        case .different: return "Отличается"
        case .directorySkipped: return "Папка: вложенные файлы не проверены"
        case .symbolicLinkSkipped: return "Ссылка: цель не проверяется"
        case .typeConflict: return "Конфликт типов"
        case .ambiguousName: return "Неоднозначное имя"
        case .unsupported: return "Специальный файл: пропущен"
        case .error: return "Ошибка проверки"
        }
    }
}

public struct DirectoryComparisonItem: Sendable {
    public let url: URL
    public let size: Int64
    public let modified: Date
    fileprivate let stamp: ComparisonStamp
}

public struct DirectoryComparisonRow: Sendable {
    public let name: String
    public let left: DirectoryComparisonItem?
    public let right: DirectoryComparisonItem?
    public let status: DirectoryComparisonStatus
    public let detail: String
    public var markLeft: Bool { [.leftOnly, .leftNewer, .different].contains(status) }
    public var markRight: Bool { [.rightOnly, .rightNewer, .different].contains(status) }
}

public enum DirectorySyncDirection: Sendable { case leftToRight, rightToLeft }
public enum DirectorySyncAction: String, Sendable {
    case copy, replace, retain, blocked
    public var description: String {
        switch self {
        case .copy: return "Скопировать"
        case .replace: return "Заменить"
        case .retain: return "Оставить"
        case .blocked: return "Пропустить"
        }
    }
}
public struct DirectorySyncPreview: Sendable {
    public let name: String
    public let source: URL?
    public let destination: URL
    public let action: DirectorySyncAction
    public let detail: String
}

/// A bounded snapshot of immediate children, not a recursive tree comparison.
/// This type deliberately has no execution API: a sync plan is only a preview.
public struct DirectoryComparisonReport: Sendable {
    public let left: URL
    public let right: URL
    public let rows: [DirectoryComparisonRow]
    public let issues: [String]
    public let cancelled: Bool
    public let limitReached: Bool
    public let contentBytesRead: Int64
    fileprivate let leftStamp: ComparisonStamp?
    fileprivate let rightStamp: ComparisonStamp?
    public var isComplete: Bool { !cancelled && !limitReached && issues.isEmpty && leftStamp != nil && rightStamp != nil }
    public var markedLeftURLs: [URL] { isComplete ? rows.filter(\.markLeft).compactMap(\.left?.url) : [] }
    public var markedRightURLs: [URL] { isComplete ? rows.filter(\.markRight).compactMap(\.right?.url) : [] }

    /// Revalidate off the main thread before using marks or presenting a plan.
    /// A later uncoordinated external write can still invalidate any snapshot.
    public func verifyCurrent(cancellation: DirectoryComparisonCancellation = .init()) throws {
        if cancellation.isCancelled { throw ComparisonStopped() }
        guard isComplete, let leftStamp, let rightStamp else {
            throw ComparisonProblem("Сравнение неполное. Повторите его перед пометкой или планированием.")
        }
        let lfd = try comparisonOpenDirectory(left)
        defer { close(lfd) }
        let rfd = try comparisonOpenDirectory(right)
        defer { close(rfd) }
        try comparisonVerify(lfd, expected: leftStamp, name: left.path)
        try comparisonVerify(rfd, expected: rightStamp, name: right.path)
        for row in rows {
            if cancellation.isCancelled { throw ComparisonStopped() }
            for (item, fd) in [(row.left, lfd), (row.right, rfd)] {
                if let item {
                    var current = stat()
                    guard fstatat(fd, item.url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                          ComparisonStamp(current) == item.stamp else {
                        throw ComparisonProblem("Снимок устарел: «\(item.url.path)» изменился. Повторите сравнение.")
                    }
                }
            }
        }
        try comparisonVerify(lfd, expected: leftStamp, name: left.path)
        try comparisonVerify(rfd, expected: rightStamp, name: right.path)
    }

    /// Includes destination-only files as retained; never suggests deletion.
    /// The caller must verifyCurrent() before presenting this snapshot as current.
    public func syncPreview(_ direction: DirectorySyncDirection) -> [DirectorySyncPreview] {
        let forward = direction == .leftToRight
        return rows.map { row in
            let source = forward ? row.left : row.right
            let target = forward ? row.right : row.left
            let destination = target?.url ?? (forward ? right : left).appendingPathComponent(row.name)
            var action: DirectorySyncAction = .blocked
            var detail = row.detail.isEmpty ? row.status.description : row.detail
            if isComplete {
                switch row.status {
                case .same: action = .retain; detail = "Совпадает по выбранным критериям."
                case .leftOnly, .rightOnly:
                    action = source == nil ? .retain : .copy
                    detail = source == nil ? "Есть только в назначении; удаление не предлагается." : "Новый файл в назначении."
                case .leftNewer, .rightNewer, .different:
                    action = .replace
                    let older = (forward && row.status == .rightNewer) || (!forward && row.status == .leftNewer)
                    detail = older ? "ВНИМАНИЕ: источник старее назначения." : "Назначение будет заменено версией источника."
                default: break
                }
            } else { detail = "Неполный или отменённый снимок; повторите сравнение." }
            return DirectorySyncPreview(name: row.name, source: source?.url, destination: destination, action: action, detail: detail)
        }
    }
}

public enum DirectoryComparisonEngine {
    /// Blocking worker entry point; UI callers dispatch this away from the main thread.
    /// Cancellation is checked for every directory entry and every 64 KiB read.
    public static func run(left: URL, right: URL, options: DirectoryComparisonOptions = .init(),
                           cancellation: DirectoryComparisonCancellation = .init(),
                           onProgress: @escaping (Int) -> Void = { _ in }) -> DirectoryComparisonReport {
        ComparisonWorker(left, right, options, cancellation, onProgress).run()
    }
}

fileprivate struct ComparisonStamp: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: Int64
    let mtime: Int
    let mtimeNS: Int
    let ctime: Int
    let ctimeNS: Int
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; mode = s.st_mode; size = Int64(s.st_size)
        mtime = s.st_mtimespec.tv_sec; mtimeNS = s.st_mtimespec.tv_nsec
        ctime = s.st_ctimespec.tv_sec; ctimeNS = s.st_ctimespec.tv_nsec
    }
    var kind: mode_t { mode & S_IFMT }
    var modified: Date { Date(timeIntervalSince1970: Double(mtime) + Double(mtimeNS) / 1_000_000_000) }
}
private struct ComparisonProblem: LocalizedError {
    let errorDescription: String?
    init(_ value: String) { errorDescription = value }
}
private struct ComparisonStopped: Error {}
private func comparisonError(_ message: String) -> ComparisonProblem {
    ComparisonProblem("\(message): \(String(cString: strerror(errno))).")
}

// Resolve only the explicitly selected root (including macOS /var and /tmp
// aliases), then walk its physical path with O_NOFOLLOW. Child links never open.
private func comparisonOpenDirectory(_ url: URL) throws -> Int32 {
    guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
          url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
        throw ComparisonProblem("Требуется абсолютный путь локального каталога.")
    }
    guard let physical = realpath(url.path, nil) else {
        throw comparisonError("Не удалось разрешить выбранный каталог «\(url.path)»")
    }
    defer { free(physical) }
    let physicalURL = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw comparisonError("Не удалось открыть корень") }
    for component in physicalURL.pathComponents.dropFirst() {
        if component == "." { continue }
        guard component != ".." else {
            close(fd); throw ComparisonProblem("Укажите путь каталога без компонентов «..».")
        }
        let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if next < 0 {
            let error = comparisonError("Не удалось открыть каталог без перехода по ссылкам «\(url.path)»")
            close(fd); throw error
        }
        close(fd); fd = next
    }
    return fd
}
private func comparisonVerify(_ fd: Int32, expected: ComparisonStamp, name: String) throws {
    var current = stat()
    guard fstat(fd, &current) == 0, ComparisonStamp(current) == expected else {
        throw ComparisonProblem("Снимок устарел: «\(name)» изменился. Повторите сравнение.")
    }
}

private final class ComparisonWorker {
    let left: URL
    let right: URL
    let options: DirectoryComparisonOptions
    let cancellation: DirectoryComparisonCancellation
    let onProgress: (Int) -> Void
    var rows: [DirectoryComparisonRow] = []
    var issues: [String] = []
    var limitReached = false
    var bytesRead: Int64 = 0
    var leftStamp: ComparisonStamp?
    var rightStamp: ComparisonStamp?
    init(_ left: URL, _ right: URL, _ options: DirectoryComparisonOptions,
         _ cancellation: DirectoryComparisonCancellation, _ onProgress: @escaping (Int) -> Void) {
        // Keep the caller's path for panel marks, including system aliases.
        self.left = left; self.right = right
        self.options = options; self.cancellation = cancellation; self.onProgress = onProgress
    }
    func report() -> DirectoryComparisonReport {
        DirectoryComparisonReport(left: left, right: right, rows: rows, issues: issues,
                                  cancelled: cancellation.isCancelled, limitReached: limitReached,
                                  contentBytesRead: bytesRead, leftStamp: leftStamp, rightStamp: rightStamp)
    }
    func checkCancellation() throws { if cancellation.isCancelled { throw ComparisonStopped() } }
    func run() -> DirectoryComparisonReport {
        do {
            guard (1...100_000).contains(options.maximumEntriesPerDirectory),
                  (1...(1_024 * 1_024 * 1_024)).contains(options.maximumContentBytesPerFile),
                  (1...(8 * 1_024 * 1_024 * 1_024)).contains(options.maximumTotalContentBytes) else {
                throw ComparisonProblem("Недопустимые пределы сравнения.")
            }
            try checkCancellation()
            let lfd = try comparisonOpenDirectory(left)
            defer { close(lfd) }
            let rfd = try comparisonOpenDirectory(right)
            defer { close(rfd) }
            var ls = stat(), rs = stat()
            guard fstat(lfd, &ls) == 0, fstat(rfd, &rs) == 0 else { throw comparisonError("Не удалось проверить каталоги") }
            leftStamp = ComparisonStamp(ls); rightStamp = ComparisonStamp(rs)
            let a = try list(lfd, root: left)
            let b = try list(rfd, root: right)
            let keys = Set(a.keys).union(b.keys).sorted()
            for key in keys {
                try checkCancellation()
                let lhs = a[key] ?? [], rhs = b[key] ?? []
                if lhs.count > 1 || rhs.count > 1 {
                    // Retain every ambiguous object so verification cannot miss one.
                    for item in lhs { append(item.url.lastPathComponent, item, nil, .ambiguousName, "Несколько имён совпали без учёта регистра. Включите учёт регистра.") }
                    for item in rhs { append(item.url.lastPathComponent, nil, item, .ambiguousName, "Несколько имён совпали без учёта регистра. Включите учёт регистра.") }
                    continue
                }
                let l = lhs.first, r = rhs.first
                let name = (l ?? r)!.url.lastPathComponent
                do { try compare(name, l, r, lfd, rfd) }
                catch is ComparisonStopped { throw ComparisonStopped() }
                catch { append(name, l, r, .error, error.localizedDescription); issues.append("\(name): \(error.localizedDescription)") }
                onProgress(rows.count)
            }
            try checkCancellation()
            // Catch mutations made during metadata-only as well as content comparisons.
            try report().verifyCurrent(cancellation: cancellation)
        } catch is ComparisonStopped {
            // Cancellation retains already compared rows, but disables marks and plans.
        } catch { issues.append(error.localizedDescription) }
        return report()
    }
    func append(_ name: String, _ l: DirectoryComparisonItem?, _ r: DirectoryComparisonItem?,
                _ status: DirectoryComparisonStatus, _ detail: String = "") {
        rows.append(DirectoryComparisonRow(name: name, left: l, right: r, status: status, detail: detail))
    }
    func list(_ fd: Int32, root: URL) throws -> [String: [DirectoryComparisonItem]] {
        let copy = dup(fd)
        guard copy >= 0 else { throw comparisonError("Не удалось прочитать каталог") }
        guard let directory = fdopendir(copy) else { close(copy); throw comparisonError("Не удалось прочитать каталог") }
        defer { closedir(directory) }
        var items: [String: [DirectoryComparisonItem]] = [:]
        var count = 0
        while true {
            try checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw comparisonError("Ошибка чтения «\(root.path)»") }
                break
            }
            guard let name = withUnsafePointer(to: &entry.pointee.d_name, { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) }
            }) else { throw ComparisonProblem("Имя в «\(root.path)» не является UTF-8; сравнение неполное.") }
            if name == "." || name == ".." { continue }
            // Bound enumeration too, including hidden entries which may be excluded.
            count += 1
            if count > options.maximumEntriesPerDirectory {
                limitReached = true
                throw ComparisonProblem("В «\(root.path)» превышен предел \(options.maximumEntriesPerDirectory) записей; сравнение неполное.")
            }
            var value = stat()
            guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw comparisonError("Не удалось проверить «\(root.appendingPathComponent(name).path)»")
            }
            if !options.includeHidden && (name.hasPrefix(".") || value.st_flags & UInt32(UF_HIDDEN) != 0) { continue }
            let stamp = ComparisonStamp(value)
            let item = DirectoryComparisonItem(url: root.appendingPathComponent(name), size: stamp.size,
                                               modified: stamp.modified, stamp: stamp)
            let key = options.caseSensitiveNames ? name : name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            items[key, default: []].append(item)
        }
        return items
    }
    func compare(_ name: String, _ l: DirectoryComparisonItem?, _ r: DirectoryComparisonItem?, _ lfd: Int32, _ rfd: Int32) throws {
        if let l, let r, l.stamp.kind != r.stamp.kind { append(name, l, r, .typeConflict); return }
        let kind = (l ?? r)!.stamp.kind
        if kind == S_IFLNK { append(name, l, r, .symbolicLinkSkipped); return }
        if kind == S_IFDIR { append(name, l, r, .directorySkipped); return }
        if kind != S_IFREG { append(name, l, r, .unsupported); return }
        guard let l else { append(name, nil, r, .rightOnly); return }
        guard let r else { append(name, l, nil, .leftOnly); return }
        let sameTime = l.stamp.mtime == r.stamp.mtime && l.stamp.mtimeNS == r.stamp.mtimeNS
        let sameSize = l.size == r.size
        // When bytes are requested, even unequal-time files are read (unless sizes differ).
        let sameBytes = !options.compareContents || !sameSize ? sameSize : try contentEqual(l, r, lfd, rfd)
        let status: DirectoryComparisonStatus
        if !sameTime { status = (l.stamp.mtime, l.stamp.mtimeNS) > (r.stamp.mtime, r.stamp.mtimeNS) ? .leftNewer : .rightNewer }
        else { status = sameSize && sameBytes ? .same : .different }
        let content = options.compareContents ? (sameSize && sameBytes ? "Байты совпадают." : "Содержимое различается.") : "Содержимое не проверялось."
        append(name, l, r, status, content)
    }
    func contentEqual(_ l: DirectoryComparisonItem, _ r: DirectoryComparisonItem, _ lfd: Int32, _ rfd: Int32) throws -> Bool {
        guard l.size <= options.maximumContentBytesPerFile else {
            throw ComparisonProblem("Файл превышает предел чтения \(options.maximumContentBytesPerFile) байт.")
        }
        guard l.size <= (options.maximumTotalContentBytes - bytesRead) / 2 else {
            limitReached = true
            throw ComparisonProblem("Достигнут общий предел чтения \(options.maximumTotalContentBytes) байт.")
        }
        let a = openat(lfd, l.url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard a >= 0 else { throw comparisonError("Не удалось открыть левый файл") }
        defer { close(a) }
        let b = openat(rfd, r.url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard b >= 0 else { throw comparisonError("Не удалось открыть правый файл") }
        defer { close(b) }
        try comparisonVerify(a, expected: l.stamp, name: l.url.path)
        try comparisonVerify(b, expected: r.stamp, name: r.url.path)
        var remaining = l.size
        var equal = true
        while remaining > 0 {
            try checkCancellation()
            let count = Int(min(65_536, remaining))
            let x = try readChunk(a, count: count), y = try readChunk(b, count: count)
            if x != y { equal = false }
            remaining -= Int64(count)
        }
        try comparisonVerify(a, expected: l.stamp, name: l.url.path)
        try comparisonVerify(b, expected: r.stamp, name: r.url.path)
        return equal
    }
    func readChunk(_ fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try checkCancellation()
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if amount < 0 { if errno == EINTR { continue }; throw comparisonError("Ошибка чтения содержимого") }
            guard amount > 0 else { throw ComparisonProblem("Содержимое усечено во время сравнения; повторите сравнение.") }
            offset += amount; bytesRead += Int64(amount)
        }
        return buffer
    }
}
