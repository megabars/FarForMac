import Foundation
import Darwin

public enum SearchFileKind: String, Codable, CaseIterable, Sendable {
    case file, directory, symbolicLink
}

public enum SearchContentMode: String, Codable, CaseIterable, Sendable {
    case none, literal, regex, hex
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
    /// Deliberate search range. The safety limit still bounds the bytes we may scan.
    public var firstContentBytes: Int?
    /// Missing in saved v1 options means UTF-8, preserving older searches.
    public var contentEncoding: ViewerEncoding?
    /// Missing in earlier saved searches preserves local-only traversal.
    public var searchArchives: Bool?
    public var searchNestedArchives: Bool?

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

public struct SearchResult: Identifiable, Codable, Sendable, Equatable {
    public var id: String { url.path }
    let capturedIdentityPath: String?
    var searchIdentityPath: String { capturedIdentityPath ?? url.path }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let modified: Date?
    public let snippet: String?
    public let lineNumber: Int?
    /// Zero-based raw byte position for HEX results; text results use lineNumber.
    public let byteOffset: Int64?
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
        return SearchResult(capturedIdentityPath: SearchLocation.localKey(url), url: url, name: url.lastPathComponent, isDirectory: kind == .directory,
                            isSymbolicLink: kind == .symbolicLink, size: stamp.size, modified: stamp.modified,
                            snippet: nil, lineNumber: nil, byteOffset: nil, stamp: stamp, contentStamp: nil)
    }

    func validateSavedReference() throws {
        guard stamp.kind != nil, stamp.size >= 0, stamp.size == size,
              (stamp.kind == .directory) == isDirectory, (stamp.kind == .symbolicLink) == isSymbolicLink,
              (0..<1_000_000_000).contains(stamp.nanoseconds),
              stamp.changedNanoseconds.map({ (0..<1_000_000_000).contains($0) }) ?? true,
              modified == stamp.modified else { throw PanelSessionError("Неверные метаданные локального снимка.") }
        if let capturedIdentityPath { try SavedReferenceValidation.localPath(capturedIdentityPath) }
        if let contentStamp {
            guard contentStamp.kind == .file, contentStamp.size >= 0,
                  (0..<1_000_000_000).contains(contentStamp.nanoseconds),
                  contentStamp.changedNanoseconds.map({ (0..<1_000_000_000).contains($0) }) ?? true else { throw PanelSessionError("Неверный снимок содержимого.") }
        }
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
        let status = cancelled ? "Поиск отменён" : (limitReached ? "Достигнут предел поиска" : (errors > 0 ? "Поиск завершён частично" : "Поиск завершён"))
        return "\(status). Проверено: \(scanned), найдено: \(matches), ошибок/пропусков: \(errors)."
    }
}

public enum SearchEvent: Sendable {
    case result(SearchResult)
    case archiveResult(ProviderSearchResult)
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
/// Results are streamed and never retained by the worker. Literal content is decoded
/// page by page with a bounded overlap; regex retains its full-file byte cap.
/// Invalid/unreadable/changed files produce visible issues even after an early match.
/// Regex deadlines are cooperative ICU deadlines, not hard real-time guarantees.
public enum SearchEngine {
    public static func validate(_ request: SearchRequest) throws {
        _ = try SearchPlan(request)
    }

    public static func run(_ request: SearchRequest, archiveLimits: ArchiveSearchLimits = .default, cancellation: SearchCancellation,
                           onEvent: @escaping (SearchEvent) -> Void) -> SearchSummary {
        do {
            return try SearchWorker(try SearchPlan(request), request, archiveLimits, cancellation, onEvent).run()
        } catch {
            onEvent(.issue(SearchIssue(path: "", message: error.localizedDescription)))
            return SearchSummary(scanned: 0, matches: 0, errors: 1,
                                 cancelled: cancellation.isCancelled, limitReached: false)
        }
    }
}

extension SearchEngine {
    static func runShared(_ request: SearchRequest, archiveLimits: ArchiveSearchLimits,
                          archiveBudget: ArchiveSearchBudget, cancellation: SearchCancellation,
                          providerCancellation: ProviderSearchCancellation,
                          shouldStop: @escaping () -> Bool,
                          onEvent: @escaping (SearchEvent) -> Void) -> SearchSummary {
        do {
            return try SearchWorker(try SearchPlan(request), request, archiveLimits, cancellation, onEvent,
                archiveBudget: archiveBudget, shouldStop: shouldStop, providerCancellation: providerCancellation).run()
        } catch {
            onEvent(.issue(SearchIssue(path: "", message: error.localizedDescription)))
            return SearchSummary(scanned: 0, matches: 0, errors: 1, cancelled: cancellation.isCancelled, limitReached: false)
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
    let changedSeconds: Int?
    let changedNanoseconds: Int?
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        size = Int64(value.st_size)
        seconds = value.st_mtimespec.tv_sec; nanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
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
    let bytes: [UInt8]?
    var hasContent: Bool { content != nil || bytes != nil }
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
        let maximum = (value.contentMode == .literal || value.contentMode == .hex) ? 4_096 * 1_024 * 1_024 : 64 * 1_024 * 1_024
        guard (1...maximum).contains(value.maximumContentBytes) else {
            throw SearchProblem("Предел чтения: до 4096 МиБ для подстроки и HEX, до 64 МиБ для Regex.")
        }
        if let first = value.firstContentBytes, !(1...maximum).contains(first) {
            throw SearchProblem("Неверный диапазон поиска в начале файла.")
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
        bytes = value.contentMode == .hex ? try SearchContentScanner.hexBytes(value.contentQuery) : nil
        if value.contentMode == .none || value.contentMode == .hex {
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
    var archives: ArchiveSearchWorker?
    let shouldStop: () -> Bool
    var stopped: Bool { cancellation.isCancelled || limitReached || shouldStop() || (archives?.limitReached ?? false) }

    init(_ plan: SearchPlan, _ request: SearchRequest, _ archiveLimits: ArchiveSearchLimits,
         _ cancellation: SearchCancellation, _ onEvent: @escaping (SearchEvent) -> Void,
         archiveBudget: ArchiveSearchBudget? = nil, shouldStop: @escaping () -> Bool = { false },
         providerCancellation: ProviderSearchCancellation? = nil) throws {
        self.plan = plan; self.cancellation = cancellation; self.onEvent = onEvent; self.shouldStop = shouldStop
        if plan.options.searchArchives == true {
            archives = try ArchiveSearchWorker(request: request, limits: archiveLimits,
                cancellation: providerCancellation ?? ProviderSearchCancellation(search: cancellation),
                shouldStop: { [weak self] in self?.stopped != false },
                visit: { [weak self] path in
                    guard let self else { return }; self.scanned += 1; self.currentPath = path; self.progress()
                }, result: { [weak self] result in
                    guard let self, !self.stopped else { return }
                    self.matches += 1; self.onEvent(.archiveResult(result))
                    if self.matches >= plan.options.maximumResults { self.limitReached = true }
                }, issue: { [weak self] path, error in
                    guard let self else { return }; self.errors += 1
                    self.onEvent(.issue(SearchIssue(path: path, message: error.localizedDescription)))
                }, progress: { [weak self] in self?.progress() }, sharedBudget: archiveBudget)
        }
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
                             cancelled: cancellation.isCancelled, limitReached: limitReached || (archives?.limitReached ?? false))
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
                        var contentMatch: SearchContentMatch?
                        if plan.hasContent {
                            // Links are content candidates only when explicitly followed.
                            if target.kind == .file && (kind != .symbolicLink || plan.options.followSymbolicLinks) {
                                contentMatch = try searchContent(url, parent: parent, name: name, expected: target,
                                                                follow: kind == .symbolicLink)
                            }
                        }
                        if !stopped && (!plan.hasContent || contentMatch != nil) {
                            if plan.hasContent {
                                var current = stat()
                                guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, SearchStamp(current) == stamp else {
                                    throw SearchProblem("Файл изменился во время поиска; результат пропущен.")
                                }
                            }
                            emitted.insert(resultKey(url))
                            matches += 1
                            onEvent(.result(SearchResult(capturedIdentityPath: SearchLocation.localKey(url), url: url, name: url.lastPathComponent,
                                                         isDirectory: target.kind == .directory,
                                                         isSymbolicLink: kind == .symbolicLink, size: stamp.size,
                                                         modified: stamp.modified, snippet: contentMatch?.snippet,
                                                         lineNumber: contentMatch?.line, byteOffset: contentMatch?.byteOffset, stamp: stamp,
                                                         contentStamp: contentMatch == nil ? nil : target)))
                            if matches >= plan.options.maximumResults { limitReached = true }
                        }
                    }
                } catch is SearchStopped {
                    return
                } catch { if !cancellation.isCancelled { issue(url, error.localizedDescription) } }
            }
        }
        if !stopped, stamp.kind == .file, let archives {
            archives.searchLocal(url, expectedSource: value) {
                var current = stat(), named = stat()
                guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0, SearchStamp(current) == stamp,
                      lstat(url.path, &named) == 0, SearchStamp(named) == stamp else {
                    throw ArchiveError.changedArchive
                }
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
                       follow: Bool) throws -> SearchContentMatch? {
        if cancellation.isCancelled { throw SearchStopped() }
        let searchSize = min(expected.size, Int64(plan.options.firstContentBytes ?? Int.max))
        guard searchSize <= Int64(plan.options.maximumContentBytes) else {
            throw SearchProblem("Содержимое пропущено: размер превышает предел \(plan.options.maximumContentBytes) байт.")
        }
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (follow ? 0 : O_NOFOLLOW))
        guard descriptor >= 0 else { throw SearchProblem(systemError("Не удалось открыть содержимое")) }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, SearchStamp(value) == expected, SearchStamp(value).kind == .file else {
            throw SearchProblem("Файл изменился или больше не является обычным файлом.")
        }
        let source = SearchByteSource(descriptor: descriptor, expected: expected, cancellation: cancellation)
        let match: SearchContentMatch?
        if let bytes = plan.bytes {
            match = try SearchContentScanner.scanBytes(source: SearchContentScanner.prefix(source, firstBytes: plan.options.firstContentBytes),
                query: bytes, cancellation: cancellation)
        } else if let expression = plan.content {
            let document = try SearchContentScanner.document(source, encoding: plan.options.contentEncoding ?? .utf8,
                firstBytes: plan.options.firstContentBytes)
            match = try SearchContentScanner.scan(document: document, expression: expression,
                literal: plan.options.contentMode == .literal, queryLength: plan.options.contentQuery.utf16.count,
                cancellation: cancellation)
        } else { return nil }
        try source.verifyUnchanged()
        guard fstatat(parent, name, &value, 0) == 0, SearchStamp(value) == expected else {
            throw SearchProblem("Содержимое изменилось во время поиска; файл пропущен.")
        }
        return match

    }
}

/// Borrows the already verified descriptor; never reopens a path during scanning.
private struct SearchByteSource: ViewerByteSource {
    let descriptor: Int32
    let expected: SearchStamp
    let cancellation: SearchCancellation
    var size: Int64 { expected.size }
    var identity: String { "search:\(expected.device):\(expected.inode)" }
    func verifyUnchanged() throws {
        if cancellation.isCancelled { throw SearchStopped() }
        var value = stat()
        guard fstat(descriptor, &value) == 0, SearchStamp(value) == expected else {
            throw SearchProblem("Содержимое изменилось во время поиска; файл пропущен.")
        }
    }
    func read(offset: Int64, count: Int) throws -> Data {
        try verifyUnchanged()
        guard offset >= 0, offset <= size, count >= 0, count <= LocalViewerSource.maximumReadCount else { throw ViewerError.invalidRange }
        var data = Data(count: min(count, Int(size - offset)))
        var readCount = 0
        while readCount < data.count {
            let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!.advanced(by: readCount), $0.count - readCount, off_t(offset) + off_t(readCount)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw SearchProblem("Не удалось прочитать содержимое: файл изменился или недоступен.") }
            readCount += count
            try verifyUnchanged()
        }
        return data
    }
}
