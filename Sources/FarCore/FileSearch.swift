import Foundation
import Darwin

public enum SearchFileKind: String, Codable, CaseIterable, Sendable {
    case file, directory, symbolicLink
}

public enum SearchContentMode: String, Codable, CaseIterable, Sendable {
    case none, literal, regex
}

public struct SearchOptions: Codable, Sendable {
    public var roots: [URL]
    public var namePattern: String = "*"
    public var contentQuery: String = ""
    public var contentMode: SearchContentMode = .none
    public var caseSensitive: Bool = false
    public var includeHidden: Bool = false
    public var followSymbolicLinks: Bool = false
    public var kinds: Set<SearchFileKind> = Set(SearchFileKind.allCases)
    public var minSize: Int64?
    public var maxSize: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var maximumResults: Int = 10_000
    public var maximumContentBytes: Int = 16 * 1_024 * 1_024

    public init(roots: [URL]) { self.roots = roots }
}

public struct SearchRequest: Sendable {
    public let options: SearchOptions
    public let maskGroups: [String: String]
    public init(options: SearchOptions, maskGroups: [String: String] = [:]) {
        self.options = options
        self.maskGroups = maskGroups
    }
}

public final class SearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public struct SearchResult: Identifiable, Codable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let modified: Date?
    public let snippet: String?
    public let lineNumber: Int?
    fileprivate let stamp: SearchStamp
    fileprivate let contentStamp: SearchStamp?

    /// Captures a manually added temporary-panel item without descending directories.
    public static func capture(_ url: URL) throws -> SearchResult {
        let url = url.standardizedFileURL
        var value = stat()
        guard url.isFileURL, lstat(url.path, &value) == 0 else {
            throw SearchProblem("Объект недоступен: «\(url.path)».")
        }
        let stamp = SearchStamp(value)
        guard let kind = stamp.kind else { throw SearchProblem("Этот тип объекта не поддерживается временной панелью.") }
        return SearchResult(url: url, name: url.lastPathComponent, isDirectory: kind == .directory,
                            isSymbolicLink: kind == .symbolicLink, size: stamp.size, modified: stamp.modified,
                            snippet: nil, lineNumber: nil, stamp: stamp, contentStamp: nil)
    }

    /// Rejects stale results before navigation, viewing or editing. A content result also
    /// verifies the followed target, including size and nanosecond modification time.
    public func verifyCurrent() throws {
        var current = stat()
        guard lstat(url.path, &current) == 0, SearchStamp(current) == stamp else {
            throw SearchProblem("Результат поиска исчез или изменился: «\(url.path)». Повторите поиск.")
        }
        if let contentStamp {
            guard fstatat(AT_FDCWD, url.path, &current, 0) == 0, SearchStamp(current) == contentStamp else {
                throw SearchProblem("Содержимое результата поиска изменилось: «\(url.path)». Повторите поиск.")
            }
        }
    }
}

public struct SearchIssue: Sendable {
    public let path: String
    public let message: String
}

public struct SearchProgress: Sendable {
    public let scanned: Int
    public let matches: Int
    public let errors: Int
    public let currentPath: String
}

public struct SearchSummary: Sendable {
    public let scanned: Int
    public let matches: Int
    public let errors: Int
    public let cancelled: Bool
    public let limitReached: Bool
    public var summary: String {
        let status = cancelled ? "Поиск отменён" : (limitReached ? "Достигнут предел результатов" : (errors > 0 ? "Поиск завершён частично" : "Поиск завершён"))
        return "\(status). Проверено: \(scanned), найдено: \(matches), ошибок/пропусков: \(errors)."
    }
}

public enum SearchEvent: Sendable {
    case result(SearchResult)
    case issue(SearchIssue)
    case progress(SearchProgress)
}

/// Synchronous local-filesystem worker; callbacks run on the calling thread.
/// Directory roots search their descendants; individual file/link roots search the entry.
/// Filters use lstat metadata (a link remains the symbolicLink kind). Following links
/// enables target content and directory descent. Hidden descendant entries are skipped
/// by name or UF_HIDDEN; explicitly selected roots are still examined.
/// Entries stream from readdir, with at most 128 open directory levels. Only ancestor
/// identities are retained, preventing cycles without an unbounded visited-path set.
/// Results are streamed and never retained by the worker. UTF-8 content must fit the
/// byte cap in full; oversized/invalid/unreadable/changed files produce visible issues.
/// Regex deadlines are cooperative ICU deadlines, not hard real-time guarantees.
public enum SearchEngine {
    public static func validate(_ request: SearchRequest) throws {
        _ = try SearchPlan(request)
    }

    public static func run(_ request: SearchRequest, cancellation: SearchCancellation,
                           onEvent: @escaping (SearchEvent) -> Void) -> SearchSummary {
        do {
            return SearchWorker(try SearchPlan(request), cancellation, onEvent).run()
        } catch {
            onEvent(.issue(SearchIssue(path: "", message: error.localizedDescription)))
            return SearchSummary(scanned: 0, matches: 0, errors: 1,
                                 cancelled: cancellation.isCancelled, limitReached: false)
        }
    }
}

private struct SearchProblem: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
private struct SearchStopped: Error {}

fileprivate struct SearchStamp: Equatable, Codable, Sendable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: Int64
    let seconds: Int
    let nanoseconds: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        size = Int64(value.st_size)
        seconds = value.st_mtimespec.tv_sec; nanoseconds = value.st_mtimespec.tv_nsec
    }
    var modified: Date { Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000) }
    var identity: SearchIdentity { SearchIdentity(device: device, inode: inode) }
    var kind: SearchFileKind? {
        switch mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return nil
        }
    }
}

private struct SearchIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}

private struct SearchDescent {
    let url: URL
    let parent: Int32
    let name: String
    let expected: SearchStamp
    let follow: Bool
    let depth: Int
}

private final class SearchDirectoryCursor {
    let descent: SearchDescent
    let directory: UnsafeMutablePointer<DIR>
    let descriptor: Int32
    init(_ descent: SearchDescent, directory: UnsafeMutablePointer<DIR>, descriptor: Int32) {
        self.descent = descent; self.directory = directory; self.descriptor = descriptor
    }
    deinit { closedir(directory) }
}

private struct SearchPlan {
    let options: SearchOptions
    let mask: FileMask
    let content: NSRegularExpression?
    init(_ request: SearchRequest) throws {
        let value = request.options
        guard !value.roots.isEmpty, value.roots.count <= 128 else {
            throw SearchProblem("Выберите от 1 до 128 корней поиска.")
        }
        guard value.roots.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") && !$0.path.utf8.contains(0) }) else {
            throw SearchProblem("Поиск поддерживает только локальные файловые пути.")
        }
        guard !value.kinds.isEmpty else { throw SearchProblem("Выберите хотя бы один тип файлов.") }
        guard (1...10_000).contains(value.maximumResults) else {
            throw SearchProblem("Предел результатов должен быть от 1 до 10000.")
        }
        guard (1...(64 * 1_024 * 1_024)).contains(value.maximumContentBytes) else {
            throw SearchProblem("Предел чтения содержимого должен быть от 1 байта до 64 МиБ.")
        }
        guard value.minSize.map({ $0 >= 0 }) ?? true, value.maxSize.map({ $0 >= 0 }) ?? true,
              value.minSize == nil || value.maxSize == nil || value.minSize! <= value.maxSize! else {
            throw SearchProblem("Неверные границы размера файла.")
        }
        guard value.modifiedAfter.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              value.modifiedBefore.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              value.modifiedAfter == nil || value.modifiedBefore == nil || value.modifiedAfter! <= value.modifiedBefore! else {
            throw SearchProblem("Неверные границы даты изменения.")
        }
        mask = try FileMask(value.namePattern, groups: request.maskGroups)
        if value.contentMode == .none {
            content = nil
        } else {
            guard !value.contentQuery.isEmpty, value.contentQuery.utf16.count <= 4_096 else {
                throw SearchProblem("Укажите запрос содержимого длиной от 1 до 4096 символов.")
            }
            let expression = value.contentMode == .literal
                ? NSRegularExpression.escapedPattern(for: value.contentQuery) : value.contentQuery
            do {
                content = try NSRegularExpression(pattern: expression, options: value.caseSensitive ? [] : [.caseInsensitive])
            } catch { throw SearchProblem("Некорректное регулярное выражение содержимого.") }
        }
        options = value
    }
}

private final class SearchWorker {
    let plan: SearchPlan
    let cancellation: SearchCancellation
    let onEvent: (SearchEvent) -> Void
    var scanned = 0
    var matches = 0
    var errors = 0
    var limitReached = false
    var ancestors = Set<SearchIdentity>()
    // At most maximumResults keys; aliases in ancestor directories collapse while
    // distinct final symbolic links and hard-link names remain distinct results.
    var emitted = Set<String>()
    var currentPath = ""
    var stopped: Bool { cancellation.isCancelled || limitReached }

    init(_ plan: SearchPlan, _ cancellation: SearchCancellation, _ onEvent: @escaping (SearchEvent) -> Void) {
        self.plan = plan; self.cancellation = cancellation; self.onEvent = onEvent
    }

    func run() -> SearchSummary {
        // Deduplication is bounded by the validated root count. No full-tree paths are kept.
        var roots = Set<String>()
        for root in plan.options.roots {
            if stopped { break }
            let url = root.standardizedFileURL
            guard roots.insert(resultKey(url)).inserted else { continue }
            var value = stat()
            guard lstat(url.path, &value) == 0 else { issue(url, systemError("Не удалось прочитать корень поиска")); continue }
            if let descent = visit(url, parent: AT_FDCWD, name: url.path, value: value, depth: 0, isRoot: true) {
                descend(descent)
            }
        }
        progress()
        return SearchSummary(scanned: scanned, matches: matches, errors: errors,
                             cancelled: cancellation.isCancelled, limitReached: limitReached)
    }

    func issue(_ url: URL, _ message: String) {
        errors += 1
        onEvent(.issue(SearchIssue(path: url.path, message: message)))
    }
    func progress() {
        onEvent(.progress(SearchProgress(scanned: scanned, matches: matches, errors: errors, currentPath: currentPath)))
    }
    func systemError(_ prefix: String) -> String { "\(prefix): \(String(cString: strerror(errno)))." }
    func resultKey(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }

    func visit(_ url: URL, parent: Int32, name: String, value: stat, depth: Int, isRoot: Bool = false) -> SearchDescent? {
        if stopped { return nil }
        let stamp = SearchStamp(value)
        if !isRoot && !plan.options.includeHidden && (name.hasPrefix(".") || (value.st_flags & UInt32(UF_HIDDEN)) != 0) { return nil }
        currentPath = url.path
        scanned += 1
        progress()
        if stopped { return nil }

        var target = stamp
        if stamp.kind == .symbolicLink && plan.options.followSymbolicLinks {
            var targetValue = stat()
            if fstatat(parent, name, &targetValue, 0) == 0 { target = SearchStamp(targetValue) }
            else { issue(url, systemError("Не удалось прочитать цель ссылки")) }
        }
        if !(isRoot && stamp.kind == .directory) {
            // Foundation/ICU may autorelease bridged strings and match objects.
            // Drain each entry, rather than retaining those until the worker exits.
            autoreleasepool {
                do {
                    if let kind = stamp.kind, plan.options.kinds.contains(kind),
                       passesMetadata(stamp), !emitted.contains(resultKey(url)),
                       try plan.mask.matchesChecked(url.lastPathComponent) {
                        var contentMatch: (snippet: String, line: Int)?
                        if plan.content != nil {
                            // Links are content candidates only when explicitly followed.
                            if target.kind == .file && (kind != .symbolicLink || plan.options.followSymbolicLinks) {
                                contentMatch = try searchContent(url, parent: parent, name: name, expected: target,
                                                                follow: kind == .symbolicLink)
                            }
                        }
                        if !stopped && (plan.content == nil || contentMatch != nil) {
                            emitted.insert(resultKey(url))
                            matches += 1
                            onEvent(.result(SearchResult(url: url, name: url.lastPathComponent,
                                                         isDirectory: target.kind == .directory,
                                                         isSymbolicLink: kind == .symbolicLink, size: stamp.size,
                                                         modified: stamp.modified, snippet: contentMatch?.snippet,
                                                         lineNumber: contentMatch?.line, stamp: stamp,
                                                         contentStamp: contentMatch == nil ? nil : target)))
                            if matches >= plan.options.maximumResults { limitReached = true }
                        }
                    }
                } catch is SearchStopped {
                    return
                } catch { issue(url, error.localizedDescription) }
            }
        }
        if stopped { return nil }
        if target.kind == .directory && (stamp.kind != .symbolicLink || plan.options.followSymbolicLinks) {
            return SearchDescent(url: url, parent: parent, name: name, expected: target,
                                 follow: stamp.kind == .symbolicLink, depth: depth)
        }
        return nil
    }

    func passesMetadata(_ stamp: SearchStamp) -> Bool {
        if let minimum = plan.options.minSize, stamp.size < minimum { return false }
        if let maximum = plan.options.maxSize, stamp.size > maximum { return false }
        if let minimum = plan.options.modifiedAfter, stamp.modified < minimum { return false }
        if let maximum = plan.options.modifiedBefore, stamp.modified > maximum { return false }
        return true
    }

    func openDirectory(_ descent: SearchDescent) -> SearchDirectoryCursor? {
        let url = descent.url
        let expected = descent.expected
        guard descent.depth < 128 else { issue(url, "Пропущен каталог: достигнут предел глубины 128."); return nil }
        guard !ancestors.contains(expected.identity) else { issue(url, "Пропущен цикл символических ссылок."); return nil }
        let descriptor = openat(descent.parent, descent.name, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC | (descent.follow ? 0 : O_NOFOLLOW))
        guard descriptor >= 0 else { issue(url, systemError("Не удалось открыть каталог")); return nil }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, SearchStamp(opened).identity == expected.identity,
              SearchStamp(opened).kind == .directory else {
            close(descriptor); issue(url, "Каталог изменился во время поиска."); return nil
        }
        guard let directory = fdopendir(descriptor) else {
            let message = systemError("Не удалось прочитать каталог")
            close(descriptor); issue(url, message); return nil
        }
        ancestors.insert(expected.identity)
        return SearchDirectoryCursor(descent, directory: directory, descriptor: descriptor)
    }

    func descend(_ descent: SearchDescent) {
        guard let first = openDirectory(descent) else { return }
        var stack = [first]
        defer { ancestors.removeAll(keepingCapacity: true) }
        // Explicit cursors avoid exhausting small worker-thread stacks on deep trees.
        while !stopped, let cursor = stack.last {
            let url = cursor.descent.url
            errno = 0
            guard let entry = readdir(cursor.directory) else {
                if errno != 0 { issue(url, systemError("Ошибка чтения каталога")) }
                ancestors.remove(cursor.descent.expected.identity)
                stack.removeLast()
                continue
            }
            let childName = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) }
            }
            guard let childName else { issue(url, "Пропущено имя файла с неверной кодировкой UTF-8."); continue }
            if childName == "." || childName == ".." { continue }
            if !plan.options.includeHidden && childName.hasPrefix(".") { continue }
            let child = url.appendingPathComponent(childName)
            var childValue = stat()
            guard fstatat(cursor.descriptor, childName, &childValue, AT_SYMLINK_NOFOLLOW) == 0 else {
                issue(child, systemError("Не удалось прочитать запись")); continue
            }
            if let next = visit(child, parent: cursor.descriptor, name: childName, value: childValue,
                                depth: cursor.descent.depth + 1), let directory = openDirectory(next) {
                stack.append(directory)
            }
        }
    }

    func searchContent(_ url: URL, parent: Int32, name: String, expected: SearchStamp,
                       follow: Bool) throws -> (snippet: String, line: Int)? {
        if cancellation.isCancelled { throw SearchStopped() }
        guard expected.size <= Int64(plan.options.maximumContentBytes) else {
            throw SearchProblem("Содержимое пропущено: размер превышает предел \(plan.options.maximumContentBytes) байт.")
        }
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (follow ? 0 : O_NOFOLLOW))
        guard descriptor >= 0 else { throw SearchProblem(systemError("Не удалось открыть содержимое")) }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, SearchStamp(value) == expected, SearchStamp(value).kind == .file else {
            throw SearchProblem("Файл изменился или больше не является обычным файлом.")
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if cancellation.isCancelled { throw SearchStopped() }
            // One extra byte distinguishes an exact-cap EOF from a growing/truncated search.
            let length = min(buffer.count, plan.options.maximumContentBytes - bytes.count + 1)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, length) }
            if count < 0 {
                if errno == EINTR { continue }
                throw SearchProblem(systemError("Не удалось прочитать содержимое"))
            }
            if count == 0 { break }
            guard bytes.count + count <= plan.options.maximumContentBytes else {
                throw SearchProblem("Содержимое пропущено: файл вырос сверх предела чтения.")
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(descriptor, &value) == 0, SearchStamp(value) == expected else {
            throw SearchProblem("Содержимое изменилось во время поиска; файл пропущен.")
        }
        guard let text = String(data: bytes, encoding: .utf8), !bytes.contains(0) else {
            throw SearchProblem("Содержимое пропущено: требуется текст UTF-8 без двоичных нулей.")
        }
        if cancellation.isCancelled { throw SearchStopped() }
        guard let expression = plan.content else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        var match: NSRange?
        var timedOut = false
        var internalError = false
        expression.enumerateMatches(in: text, options: [.reportProgress, .reportCompletion],
                                    range: NSRange(text.startIndex..., in: text)) { result, flags, stop in
            if self.cancellation.isCancelled { stop.pointee = true }
            else if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; stop.pointee = true }
            else if flags.contains(.internalError) { internalError = true; stop.pointee = true }
            else if let result { match = result.range; stop.pointee = true }
        }
        if cancellation.isCancelled { throw SearchStopped() }
        if timedOut || ProcessInfo.processInfo.systemUptime >= deadline {
            throw SearchProblem("Содержимое пропущено: превышено время проверки выражения (50 мс).")
        }
        if internalError { throw SearchProblem("Содержимое пропущено: ошибка выполнения регулярного выражения.") }
        guard let match else { return nil }
        let nsText = text as NSString
        // Bound the snippet even for files consisting of a single very long line.
        var start = max(0, match.location - 80)
        var end = min(nsText.length, max(match.location + min(match.length, 160), match.location + 80))
        if start > 0, (0xDC00...0xDFFF).contains(nsText.character(at: start)) { start -= 1 }
        if end < nsText.length, end > 0, (0xD800...0xDBFF).contains(nsText.character(at: end - 1)) { end += 1 }
        let snippet = nsText.substring(with: NSRange(location: start, length: end - start))
            .components(separatedBy: .newlines).joined(separator: " ")
        var line = 1
        var previousWasCR = false
        for (index, unit) in text.utf16.prefix(match.location).enumerated() {
            if index & 65_535 == 0, cancellation.isCancelled { throw SearchStopped() }
            switch unit {
            case 0x0D, 0x85, 0x2028, 0x2029: line += 1
            case 0x0A: if !previousWasCR { line += 1 }
            default: break
            }
            previousWasCR = unit == 0x0D
        }
        return (snippet, line)
    }
}
