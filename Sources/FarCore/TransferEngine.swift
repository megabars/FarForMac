import Foundation
import Darwin

public struct TransferRequest: Sendable {
    public let sources: [URL]
    public let destination: URL
    public let move: Bool
    public let propagateDescriptions: Bool
    public let descriptionEncodings: [String: FileDescriptionEncoding]
    public let localOptions: LocalTransferOptions?
    fileprivate let sourceSnapshots: [TransferStamp?]
    public init(sources: [URL], destination: URL, move: Bool, propagateDescriptions: Bool = true,
                descriptionEncodings: [String: FileDescriptionEncoding] = [:], localOptions: LocalTransferOptions? = nil) {
        self.sources = sources; self.destination = destination; self.move = move
        self.propagateDescriptions = propagateDescriptions; self.descriptionEncodings = descriptionEncodings
        self.localOptions = localOptions
        self.sourceSnapshots = sources.map { try? TransferStamp($0) }
    }
}

public final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public struct TransferProgress: Sendable {
    public let phase: String
    public let currentPath: String
    public let fileBytes: Int64
    public let fileTotalBytes: Int64
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let completedItems: Int
    public let totalItems: Int
    public init(phase: String, currentPath: String, fileBytes: Int64, fileTotalBytes: Int64,
                completedBytes: Int64, totalBytes: Int64, completedItems: Int, totalItems: Int) {
        self.phase = phase; self.currentPath = currentPath; self.fileBytes = fileBytes
        self.fileTotalBytes = fileTotalBytes; self.completedBytes = completedBytes
        self.totalBytes = totalBytes; self.completedItems = completedItems; self.totalItems = totalItems
    }
}

public struct TransferConflict: Sendable {
    public let source: URL
    public let destination: URL
    public let isDirectoryMerge: Bool
    public let canReplace: Bool
    public let canAppend: Bool
    public let isReadOnlyConfirmation: Bool
    public let sourceSize: Int64?
    public let destinationSize: Int64?
    public let sourceModified: Date?
    public let destinationModified: Date?
    public let suggestedName: String?
    public init(source: URL, destination: URL, isDirectoryMerge: Bool, canReplace: Bool = true,
                canAppend: Bool = false, isReadOnlyConfirmation: Bool = false,
                sourceSize: Int64? = nil, destinationSize: Int64? = nil,
                sourceModified: Date? = nil, destinationModified: Date? = nil, suggestedName: String? = nil) {
        self.source = source; self.destination = destination; self.isDirectoryMerge = isDirectoryMerge
        self.canReplace = canReplace
        self.canAppend = canAppend; self.isReadOnlyConfirmation = isReadOnlyConfirmation
        self.sourceSize = sourceSize; self.destinationSize = destinationSize
        self.sourceModified = sourceModified; self.destinationModified = destinationModified
        self.suggestedName = suggestedName
    }
}
public enum TransferDecision: Sendable { case replace, skip, rename(String), renameAutomatically, append, merge, cancel }
public struct TransferFailure: Sendable {
    public let source: URL
    public let destination: URL
    public let message: String
    public init(source: URL, destination: URL, message: String) {
        self.source = source; self.destination = destination; self.message = message
    }
}
public enum TransferErrorDecision: Sendable { case retry, skip, cancel }

public struct TransferResult: Sendable {
    public let completed: Int
    public let skipped: Int
    public let failed: Int
    public let cancelled: Bool
    public let issues: [String]
    public var summary: String {
        let status = cancelled ? "Операция отменена" : (failed > 0 || skipped > 0 || !issues.isEmpty ? "Операция завершена частично" : "Операция завершена")
        return "\(status). Обработано: \(completed), пропущено: \(skipped), ошибок: \(failed)."
    }
    public init(completed: Int, skipped: Int, failed: Int, cancelled: Bool, issues: [String]) {
        self.completed = completed; self.skipped = skipped; self.failed = failed
        self.cancelled = cancelled; self.issues = issues
    }
}

/// A synchronous worker. Callbacks execute on the caller's worker thread. Regular files
/// (including hard links) are independent copies; symbolic links retain their link text.
/// Completed work is retained on cancellation; this API does not promise rollback.
public enum TransferEngine {
    public static func run(_ request: TransferRequest, cancellation: TransferCancellation,
                           onProgress: @escaping (TransferProgress) -> Void,
                           onConflict: @escaping (TransferConflict) -> TransferDecision,
                           onError: @escaping (TransferFailure) -> TransferErrorDecision) -> TransferResult {
        Worker(request, cancellation, onProgress, onConflict, onError).run()
    }
}

private struct TransferProblem: LocalizedError {
    let text: String
    var errorDescription: String? { text }
    init(_ text: String) { self.text = text }
}
private struct TransferStopped: Error {}

fileprivate struct TransferStamp: Equatable, @unchecked Sendable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: Int64
    let links: nlink_t
    let modification: timespec
    let change: timespec
    let info: stat
    var directory: Bool { mode & S_IFMT == S_IFDIR }
    var link: Bool { mode & S_IFMT == S_IFLNK }
    var regular: Bool { mode & S_IFMT == S_IFREG }
    var modifiedDate: Date { Date(timeIntervalSince1970: Double(modification.tv_sec) + Double(modification.tv_nsec) / 1e9) }
    func newer(than other: Self) -> Bool {
        modification.tv_sec > other.modification.tv_sec ||
            (modification.tv_sec == other.modification.tv_sec && modification.tv_nsec > other.modification.tv_nsec)
    }
    static func == (a: Self, b: Self) -> Bool {
        a.device == b.device && a.inode == b.inode && a.mode == b.mode && a.size == b.size &&
        a.modification.tv_sec == b.modification.tv_sec && a.modification.tv_nsec == b.modification.tv_nsec &&
        a.change.tv_sec == b.change.tv_sec && a.change.tv_nsec == b.change.tv_nsec
    }
    func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode }
    // rename changes ctime. All other captured fields must still match after a swap.
    func sameContentAfterRename(_ other: Self) -> Bool {
        sameObject(other) && mode == other.mode && size == other.size &&
        modification.tv_sec == other.modification.tv_sec && modification.tv_nsec == other.modification.tv_nsec
    }
    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        device = info.st_dev; inode = info.st_ino; mode = info.st_mode
        size = info.st_size; links = info.st_nlink
        modification = info.st_mtimespec; change = info.st_ctimespec
        self.info = info
    }
}
private struct TransferNode {
    let source: URL
    let stamp: TransferStamp
    let children: [TransferNode]
    let hasExcludedChildren: Bool
    var bytes: Int64 { stamp.directory ? children.reduce(0) { $0 + $1.bytes } : (stamp.link ? 0 : stamp.size) }
    // Count files, links and empty directories; container directories aren't counted twice.
    var items: Int { children.isEmpty ? 1 : children.reduce(0) { $0 + $1.items } }
}

private struct FilteredDescriptions {
    let source: FileDescriptions
    let publishedNames: Set<String>
}

private struct TransferPublication {
    let stamps: [String: TransferStamp]
    let filteredDescriptions: [URL: FilteredDescriptions]
}

private final class Worker {
    let request: TransferRequest
    let cancellation: TransferCancellation
    let progress: (TransferProgress) -> Void
    let conflict: (TransferConflict) -> TransferDecision
    let failure: (TransferFailure) -> TransferErrorDecision
    let fm = FileManager.default
    var completed = 0, skipped = 0, failed = 0, totalItems = 0
    var completedBytes: Int64 = 0, totalBytes: Int64 = 0, stagedBytes: Int64 = 0
    var issues: [String] = []
    var stopped = false
    var acceptRefreshedSources = false
    var sourceLeaves: [TransferNode] = []
    var cleanupStamps: [URL: TransferStamp] = [:]
    var explicitDescriptionDirectories = Set<String>()
    var filter: LocalTransferFilter?

    init(_ request: TransferRequest, _ cancellation: TransferCancellation,
         _ progress: @escaping (TransferProgress) -> Void,
         _ conflict: @escaping (TransferConflict) -> TransferDecision,
         _ failure: @escaping (TransferFailure) -> TransferErrorDecision) {
        self.request = request; self.cancellation = cancellation
        self.progress = progress; self.conflict = conflict; self.failure = failure
    }
    func check() throws { if cancellation.isCancelled || stopped { throw TransferStopped() } }
    func emit(_ phase: String, _ url: URL, _ bytes: Int64 = 0, _ size: Int64 = 0) {
        progress(TransferProgress(phase: phase, currentPath: url.path, fileBytes: bytes,
                                  fileTotalBytes: size, completedBytes: completedBytes + stagedBytes,
                                  totalBytes: totalBytes, completedItems: completed, totalItems: totalItems))
    }
    func run() -> TransferResult {
        guard !request.sources.isEmpty else { return result() }
        var plan: [(TransferNode, URL)] = []
        while true {
            do { try check(); plan = try preflight(); break }
            catch is TransferStopped { stopped = true; return result() }
            catch {
                let message = error.localizedDescription
                switch failure(TransferFailure(source: request.sources[0], destination: request.destination, message: message)) {
                case .retry: acceptRefreshedSources = true; continue
                case .skip: issues.append(message); failed = request.sources.count; return result()
                case .cancel: issues.append(message); stopped = true; return result()
                }
            }
        }
        totalBytes = plan.reduce(0) { $0 + $1.0.bytes }; totalItems = plan.reduce(0) { $0 + $1.0.items }
        sourceLeaves = plan.flatMap { leaves($0.0) }
        for (node, target) in plan where node.source.lastPathComponent == "descript.ion" || target.lastPathComponent == "descript.ion" {
            explicitDescriptionDirectories.insert(FileDescriptionEncoding.directoryKey(node.source.deletingLastPathComponent()))
            explicitDescriptionDirectories.insert(FileDescriptionEncoding.directoryKey(target.deletingLastPathComponent()))
        }
        for (node, destination) in plan {
            do { try check(); try transfer(node, to: destination) }
            catch is TransferStopped { stopped = true; break }
            catch { issues.append(error.localizedDescription); failed += node.items }
        }
        emit(stopped || cancellation.isCancelled ? "Отменено" : "Завершено", request.destination)
        return result()
    }
    func result() -> TransferResult {
        TransferResult(completed: completed, skipped: skipped, failed: failed,
                       cancelled: stopped || cancellation.isCancelled, issues: issues)
    }
    func stampIfPresent(_ url: URL) throws -> TransferStamp? {
        do { return try TransferStamp(url) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
    // Resolve parent links without following the final selected symbolic link.
    func identity(_ url: URL) -> URL {
        let url = url.standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        if let resolved = realpath(parent.path, nil) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(url.lastPathComponent)
        }
        return parent.appendingPathComponent(url.lastPathComponent)
    }
    func directoryIdentity(_ url: URL) -> String {
        if let resolved = realpath(url.path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        return identity(url).path
    }
    func inside(_ path: String, _ parent: String) -> Bool { path == parent || path.hasPrefix(parent == "/" ? "/" : parent + "/") }
    func scan(_ source: URL) throws -> TransferNode? {
        try check(); emit("Проверка", source)
        let stamp = try TransferStamp(source)
        if let filter, try !filter.allows(name: source.lastPathComponent, info: stamp.info) { return nil }
        guard stamp.directory || stamp.link || stamp.mode & S_IFMT == S_IFREG else {
            throw TransferProblem("Специальные файлы не поддерживаются: «\(source.path)».")
        }
        if !stamp.link && access(source.path, stamp.directory ? R_OK | X_OK : R_OK) != 0 {
            throw TransferProblem("Нет доступа к источнику «\(source.path)».")
        }
        let entries = stamp.directory ? try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent } : []
        let children = try entries.compactMap { try scan($0) }
        guard try TransferStamp(source) == stamp else { throw TransferProblem("Источник изменился при проверке: «\(source.path)».") }
        if filter != nil, stamp.directory, children.isEmpty { return nil }
        return TransferNode(source: source, stamp: stamp, children: children,
                            hasExcludedChildren: entries.count != children.count || children.contains(where: \.hasExcludedChildren))
    }
    func preflight() throws -> [(TransferNode, URL)] {
        guard request.destination.isFileURL && request.sources.allSatisfy(\.isFileURL) else {
            throw TransferProblem("Поддерживаются только локальные файловые пути.")
        }
        let layout = try LocalTransferLayout(destination: request.destination, sourceCount: request.sources.count,
                                             forceDirectory: request.localOptions?.forceDirectory == true, permitMask: request.localOptions != nil)
        let existingParent = try writableAncestor(of: layout.parent)
        if !acceptRefreshedSources {
            for (source, expected) in zip(request.sources, request.sourceSnapshots) {
                guard try stampIfPresent(source) == expected else {
                    throw TransferProblem("Источник изменился после добавления в очередь: «\(source.path)». Повтор явно примет новую версию.")
                }
            }
        }
        guard !request.sources.contains(where: { $0.standardizedFileURL.path == "/" }) else {
            throw TransferProblem("Корневой каталог нельзя переносить.")
        }
        if let options = request.localOptions, !options.filterRules.isEmpty {
            filter = try LocalTransferFilter(options.filterRules, groups: options.maskGroups)
        }
        let nodes = try request.sources.compactMap { try scan($0.standardizedFileURL) }
        for (index, node) in nodes.enumerated() {
            guard node.source.path != "/" else { throw TransferProblem("Корневой каталог нельзя переносить.") }
            for other in nodes.dropFirst(index + 1) {
                let left = node.stamp.link ? identity(node.source).path : directoryIdentity(node.source)
                let right = other.stamp.link ? identity(other.source).path : directoryIdentity(other.source)
                if inside(right, left) || inside(left, right) {
                    throw TransferProblem("Источники совпадают или вложены друг в друга. Выполните операции отдельно.")
                }
            }
        }
        var plan: [(TransferNode, URL)] = []
        var targets = Set<String>()
        let sensitive = (try? existingParent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? true
        for node in nodes {
            let target = try layout.target(for: node.source)
            let name = target.lastPathComponent.precomposedStringWithCanonicalMapping
            let key = sensitive ? name : name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard targets.insert(key).inserted else { throw TransferProblem("Несколько источников имеют одинаковое имя назначения: «\(name)».") }
            for source in nodes { try validateTarget(source, target) }
            plan.append((node, target))
        }
        if let available = (try? fm.attributesOfFileSystem(forPath: existingParent.path)[.systemFreeSize] as? NSNumber)?.int64Value {
            let required = nodes.reduce(Int64(0)) { $0 + $1.bytes }
            guard required <= available else { throw TransferProblem("Недостаточно свободного места: нужно \(required) байт, доступно \(available).") }
        }
        return plan
    }
    func writableAncestor(of parent: URL) throws -> URL {
        var ancestor = parent
        while true {
            var directory: ObjCBool = false
            if fm.fileExists(atPath: ancestor.path, isDirectory: &directory) {
                guard directory.boolValue, access(ancestor.path, W_OK | X_OK) == 0 else { break }
                return ancestor
            }
            guard request.localOptions != nil, ancestor.path != "/", try stampIfPresent(ancestor) == nil else { break }
            ancestor.deleteLastPathComponent()
        }
        throw TransferProblem("Папка назначения недоступна для записи: «\(parent.path)».")
    }
    func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw TransferProblem("Недопустимое новое имя: «\(name)».")
        }
    }
    func prepareParent(of target: URL) throws {
        let parent = target.deletingLastPathComponent()
        let ancestor = try writableAncestor(of: parent)
        guard parent.path != ancestor.path else { return }
        var cursor = parent, components: [String] = []
        while cursor.path != ancestor.path {
            components.append(cursor.lastPathComponent)
            cursor.deleteLastPathComponent()
        }
        var descriptor = open(ancestor.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        for name in components.reversed() {
            try check()
            guard mkdirat(descriptor, name, 0o777) == 0 || errno == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(descriptor)
            descriptor = child
        }
        var anchored = stat(), visible = stat()
        guard fstat(descriptor, &anchored) == 0, lstat(parent.path, &visible) == 0,
              anchored.st_dev == visible.st_dev, anchored.st_ino == visible.st_ino else {
            throw TransferProblem("Путь назначения изменился при создании папок: «\(parent.path)».")
        }
    }
    func validateTarget(_ node: TransferNode, _ target: URL) throws {
        let source = identity(node.source), destination = identity(target)
        let sameInode = try stampIfPresent(target).map { node.stamp.sameObject($0) } == true
        if source.path == destination.path || sameInode {
            throw TransferProblem("Источник и назначение совпадают: «\(node.source.path)».")
        }
        if node.stamp.directory && inside(receiptKey(target), directoryIdentity(node.source)) {
            throw TransferProblem("Нельзя поместить папку внутрь неё самой: «\(target.path)».")
        }
    }
    func verify(_ node: TransferNode) throws {
        try check()
        guard try TransferStamp(node.source) == (cleanupStamps[node.source] ?? node.stamp) else {
            throw TransferProblem("Источник изменился во время операции: «\(node.source.path)».")
        }
        for child in node.children { try verify(child) }
    }
    func transfer(_ initial: TransferNode, to originalTarget: URL) throws {
        var node = initial
        var target = originalTarget
        var rescan = false
        let startingCompleted = completed, startingSkipped = skipped, startingFailed = failed
        while true {
            try check()
            do {
                if rescan {
                    guard let refreshed = try scan(node.source) else { skipped += node.items; return }
                    // A partially merged move may already have removed published children.
                    // Keep the original budget and grow it for newly accepted source data.
                    totalBytes = max(totalBytes, completedBytes + refreshed.bytes)
                    totalItems = max(totalItems, completed + skipped + failed + refreshed.items)
                    for leaf in leaves(refreshed) { cleanupStamps.removeValue(forKey: leaf.source) }
                    node = refreshed; rescan = false
                }
                try validateTarget(node, target)
                try prepareParent(of: target)
                let existing = try stampIfPresent(target)
                var append = false
                if let existing {
                    emit("Конфликт", target)
                    let decision = resolveConflict(node, target, existing)
                    try check()
                    switch decision {
                    case .cancel: stopped = true; throw TransferStopped()
                    case .skip: skipped += node.items; return
                    case .rename(let name):
                        try validateName(name)
                        target = target.deletingLastPathComponent().appendingPathComponent(name)
                        continue
                    case .renameAutomatically:
                        target = try unusedName(for: target)
                        continue
                    case .merge:
                        guard node.stamp.directory && existing.directory else { throw TransferProblem("Слияние доступно только для двух папок.") }
                        guard try TransferStamp(target) == existing else { continue }
                        try verify(node)
                        var metadata = prepareDescriptions(node.source, target)
                        try merge(node, target: target, expected: existing) {
                            if let error = metadata.error { self.descriptionWarning(error, source: node.source, target: target); return false }
                            do { try metadata.plan?.publishDescription(); if request.move { try metadata.plan?.verifySourceDescription() }; return true }
                            catch { self.descriptionWarning(error, source: node.source, target: target); return false }
                        }
                        finishSourceDescription(&metadata.plan, source: node.source, target: target)
                        return
                    case .replace:
                        guard !node.stamp.directory && !existing.directory else {
                            throw TransferProblem("Папки нельзя заменять целиком. Выберите слияние или новое имя.")
                        }
                    case .append:
                        guard node.stamp.regular && existing.regular else {
                            throw TransferProblem("Добавление доступно только для двух обычных файлов.")
                        }
                        append = true
                    }
                }
                var metadata = prepareDescriptions(node.source, target)
                let receipt = try publish(node, to: target, replacing: existing, append: append)
                completed += node.items; completedBytes += node.bytes
                var metadataReady = metadata.error == nil
                do { try metadata.plan?.publishDescription(); if request.move { try metadata.plan?.verifySourceDescription() } }
                catch { metadataReady = false; descriptionWarning(error, source: node.source, target: target) }
                if let error = metadata.error { descriptionWarning(error, source: node.source, target: target) }
                // A metadata failure must never trigger a file-operation retry or remove
                // the source whose description could not be retained at the destination.
                if request.move && metadataReady {
                    do { try removePublishedSource(node, target: target, receipt: receipt) }
                    catch { finishSourceDescription(&metadata.plan, source: node.source, target: target); throw error }
                    finishSourceDescription(&metadata.plan, source: node.source, target: target)
                } else if request.move && !metadataReady {
                    issues.append("Копия сохранена; источник оставлен из-за ошибки описаний: «\(node.source.path)».")
                }
                return
            } catch is TransferStopped { throw TransferStopped() }
            catch {
                let message = "«\(node.source.path)» → «\(target.path)»: \(error.localizedDescription)"
                switch failure(TransferFailure(source: node.source, destination: target, message: message)) {
                case .retry: rescan = true; continue
                case .skip:
                    issues.append(message)
                    let handled = completed - startingCompleted + skipped - startingSkipped + failed - startingFailed
                    failed += max(1, node.items - handled)
                    return
                case .cancel: issues.append(message); stopped = true; throw TransferStopped()
                }
            }
        }
    }
    func resolveConflict(_ node: TransferNode, _ target: URL, _ existing: TransferStamp) -> TransferDecision {
        let isMerge = node.stamp.directory && existing.directory
        let canReplace = !node.stamp.directory && !existing.directory
        let canAppend = node.stamp.regular && existing.regular
        func ask(readOnly: Bool = false) -> TransferDecision {
            conflict(TransferConflict(source: node.source, destination: target, isDirectoryMerge: isMerge,
                                      canReplace: canReplace, canAppend: canAppend,
                                      isReadOnlyConfirmation: readOnly, sourceSize: node.stamp.size,
                                      destinationSize: existing.size, sourceModified: node.stamp.modifiedDate,
                                      destinationModified: existing.modifiedDate,
                                      suggestedName: readOnly ? nil : (try? unusedName(for: target).lastPathComponent)))
        }
        let decision: TransferDecision
        if request.localOptions != nil, isMerge {
            // FAR walks into an existing directory and asks about conflicting leaves.
            decision = .merge
        } else {
            switch request.localOptions?.conflictPolicy ?? .ask {
            case .ask: decision = ask()
            case .overwrite: decision = canReplace ? .replace : ask()
            case .skip: decision = .skip
            case .rename: decision = .renameAutomatically
            case .append: decision = canAppend ? .append : ask()
            case .newer: decision = canReplace && node.stamp.newer(than: existing) ? .replace : .skip
            }
        }
        if request.localOptions?.confirmReadOnly == true, existing.regular, existing.mode & S_IWUSR == 0 {
            switch decision {
            case .replace, .append:
                switch ask(readOnly: true) {
                case .replace: return decision
                case .cancel: return .cancel
                default: return .skip
                }
            default: break
            }
        }
        return decision
    }
    func unusedName(for target: URL) throws -> URL {
        let name = target.lastPathComponent as NSString
        let stem = name.deletingPathExtension, suffix = name.pathExtension
        for index in 2...10_000 {
            try check()
            let candidate = target.deletingLastPathComponent().appendingPathComponent(
                stem + " (\(index))" + (suffix.isEmpty ? "" : "." + suffix))
            if try stampIfPresent(candidate) == nil { return candidate }
        }
        throw TransferProblem("Не удалось подобрать свободное имя назначения.")
    }
    func prepareDescriptions(_ source: URL, _ target: URL) -> (plan: FileDescriptionTransfer?, error: Error?) {
        guard request.propagateDescriptions,
              !explicitDescriptionDirectories.contains(FileDescriptionEncoding.directoryKey(source.deletingLastPathComponent())),
              !explicitDescriptionDirectories.contains(FileDescriptionEncoding.directoryKey(target.deletingLastPathComponent())) else { return (nil, nil) }
        do { return (try FileDescriptionTransfer.prepare(source: source, destination: target, encodings: request.descriptionEncodings), nil) }
        catch { return (nil, error) }
    }
    func descriptionWarning(_ error: Error, source: URL, target: URL) {
        issues.append("Файловая операция выполнена, но описания «\(source.path)» → «\(target.path)» обновлены не полностью: \(error.localizedDescription)")
    }
    func finishSourceDescription(_ plan: inout FileDescriptionTransfer?, source: URL, target: URL) {
        guard request.move else { return }
        do {
            guard try stampIfPresent(source) == nil else { return }
            try plan?.removeSourceDescription()
        } catch { descriptionWarning(error, source: source, target: target) }
    }
    func merge(_ node: TransferNode, target: URL, expected: TransferStamp, publishDescription: () -> Bool) throws {
        // The existing directory is a container only. Its own metadata is retained.
        // Each child gets its own conflict and atomic publication boundary.
        let beforeSkipped = skipped, beforeFailed = failed
        let control = request.propagateDescriptions ? node.children.first(where: { $0.source.lastPathComponent == "descript.ion" && $0.stamp.mode & S_IFMT == S_IFREG }) : nil
        let payload = node.children.filter { $0.source != control?.source }
        if let control {
            // The control file is managed as records, not copied as a selected
            // payload. Keep the same single-container budget as an empty folder
            // when there are no payload children, otherwise remove its item count.
            totalBytes -= control.bytes
            if !payload.isEmpty { totalItems -= control.items }
            else { totalItems += 1 - control.items }
        }
        for child in payload {
            try check()
            guard let current = try stampIfPresent(target), current.directory, current.sameObject(expected) else {
                throw TransferProblem("Папка назначения изменилась во время слияния: «\(target.path)».")
            }
            try transfer(child, to: target.appendingPathComponent(child.source.lastPathComponent))
        }
        if !request.move { try verify(node) }
        if payload.isEmpty { completed += 1 }
        // Metadata follows completed work, before any container removal. A warning
        // retains the original directory instead of discarding its parent record.
        let metadataReady = publishDescription()
        if request.move && metadataReady && !node.hasExcludedChildren && skipped == beforeSkipped && failed == beforeFailed {
            // Remove only an empty original directory; never recursively delete a merged tree.
            while true {
                try check()
                guard let sourceDirectory = try stampIfPresent(node.source), sourceDirectory.directory,
                      sourceDirectory.sameObject(node.stamp) else {
                    throw TransferProblem("Исходная папка была заменена после слияния; она сохранена: «\(node.source.path)».")
                }
                if rmdir(node.source.path) == 0 { break }
                if request.propagateDescriptions,
                   let remaining = try? fm.contentsOfDirectory(atPath: node.source.path), remaining == ["descript.ion"] {
                    do {
                        let key = FileDescriptionEncoding.directoryKey(node.source)
                        let descriptions = try FileDescriptions.load(directory: node.source, encoding: request.descriptionEncodings[key] ?? .utf8)
                        if try descriptions.removeEmptyFileIfUnchanged(), rmdir(node.source.path) == 0 {
                            break
                        }
                    } catch { descriptionWarning(error, source: node.source, target: target) }
                    issues.append("Данные перенесены; исходная папка с оставшимися строками descript.ion сохранена: «\(node.source.path)».")
                    return
                }
                let message = "Данные перенесены, но исходную папку удалить не удалось: «\(node.source.path)»."
                switch failure(TransferFailure(source: node.source, destination: target, message: message)) {
                case .retry: continue
                case .skip: issues.append(message); failed += 1; return
                case .cancel: issues.append(message); stopped = true; throw TransferStopped()
                }
            }
        }
    }
    func publish(_ node: TransferNode, to target: URL, replacing existing: TransferStamp?, append: Bool) throws -> TransferPublication {
        let staging = target.deletingLastPathComponent().appendingPathComponent(".farmac-transfer-\(UUID().uuidString)")
        var ownsStaging = false
        var ownedStamp: TransferStamp?
        defer {
            stagedBytes = 0
            if ownsStaging, let ownedStamp,
               let current = try? TransferStamp(staging), current.sameObject(ownedStamp) {
                cleanupOwned(staging)
            }
        }
        try verify(node)
        // All creation is exclusive, so cleanup can only touch this operation's staging object.
        var filteredDescriptions: [URL: FilteredDescriptions] = [:]
        try copy(node, to: staging, appendingTo: append ? target : nil, destinationStamp: existing,
                 filteredDescriptions: &filteredDescriptions, rootCreated: {
            ownsStaging = true; ownedStamp = try? TransferStamp(staging)
        })
        try verify(node); try check()
        let stagedReceipt = try receipt(node, physical: staging, logical: target, filteredDescriptions: filteredDescriptions)
        guard try stampIfPresent(target) == existing else {
            throw TransferProblem("Назначение изменилось после выбора действия. Повторите операцию для нового конфликта.")
        }
        if let existing {
            guard renamex_np(staging.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // Check what was displaced. Never discard an unexpected concurrent replacement.
            guard let displaced = try stampIfPresent(staging), displaced.sameContentAfterRename(existing) else {
                // Keep both versions available for recovery rather than delete an unowned object.
                ownsStaging = false
                throw TransferProblem("Назначение изменилось при публикации. Предыдущая версия сохранена: «\(staging.path)».")
            }
            ownedStamp = displaced
        } else {
            guard renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            ownsStaging = false
        }
        var published: [String: TransferStamp] = [:]
        for (path, expected) in stagedReceipt {
            let url = URL(fileURLWithPath: path)
            let actual = try TransferStamp(url)
            guard actual.sameContentAfterRename(expected) else {
                throw TransferProblem("Опубликованная копия изменилась; источник сохранён: «\(url.path)».")
            }
            published[path] = actual
        }
        return TransferPublication(stamps: published, filteredDescriptions: filteredDescriptions)
    }
    func receiptKey(_ url: URL) -> String {
        // Foundation's standardization can choose /tmp or /private/tmp depending
        // on whether a path exists. Canonicalize only its nearest existing parent
        // with realpath, then append missing components without URL directory hints.
        var parent = url.deletingLastPathComponent()
        var remaining = [url.lastPathComponent]
        while true {
            if let resolved = realpath(parent.path, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return (base == "/" ? "" : base) + "/" + remaining.reversed().joined(separator: "/")
            }
            guard parent.path != "/" else { return url.path }
            remaining.append(parent.lastPathComponent)
            parent = parent.deletingLastPathComponent()
        }
    }
    func receipt(_ node: TransferNode, physical: URL, logical: URL,
                 filteredDescriptions: [URL: FilteredDescriptions]) throws -> [String: TransferStamp] {
        // URL equality includes directory hints/trailing slashes, which can change once
        // a previously absent destination is published. Filesystem paths do not.
        var result = [receiptKey(logical): try TransferStamp(physical)]
        for child in node.children {
            let name = child.source.lastPathComponent
            result.merge(try receipt(child, physical: physical.appendingPathComponent(name),
                                     logical: logical.appendingPathComponent(name), filteredDescriptions: filteredDescriptions)) { _, new in new }
        }
        if filteredDescriptions[node.source] != nil,
           let control = try stampIfPresent(physical.appendingPathComponent("descript.ion")) {
            result[receiptKey(logical.appendingPathComponent("descript.ion"))] = control
        }
        return result
    }
    func copy(_ node: TransferNode, to target: URL, appendingTo previous: URL? = nil,
              destinationStamp: TransferStamp? = nil, filteredDescriptions: inout [URL: FilteredDescriptions],
              rootCreated: () -> Void = {}) throws {
        try check()
        if node.stamp.directory {
            try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            rootCreated()
            for child in node.children {
                try copy(child, to: target.appendingPathComponent(child.source.lastPathComponent), filteredDescriptions: &filteredDescriptions)
            }
            if node.hasExcludedChildren, request.propagateDescriptions,
               let descriptions = try stageFilteredDescriptions(node, at: target) {
                filteredDescriptions[node.source] = descriptions
            }
        } else if node.stamp.link {
            let text = try fm.destinationOfSymbolicLink(atPath: node.source.path)
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: text)
            rootCreated(); emit("Копирование ссылки", node.source)
        } else {
            let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            rootCreated()
            defer { close(output) }
            if let previous, let destinationStamp {
                try copyBytes(from: previous, expected: destinationStamp, to: output) { copied in
                    self.emit("Подготовка добавления", previous, copied, destinationStamp.size)
                }
            }
            var previousBytes: Int64 = 0
            try copyBytes(from: node.source, expected: node.stamp, to: output) { copied in
                self.stagedBytes += copied - previousBytes
                previousBytes = copied
                self.emit("Копирование", node.source, copied, node.stamp.size)
            }
            guard fsync(output) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        try check()
        // COPYFILE_METADATA carries stat information, ACLs, xattrs and resource forks.
        let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
        let metadataSource = previous ?? node.source
        guard copyfile(metadataSource.path, target.path, nil, flags) == 0 else {
            throw TransferProblem("Не удалось сохранить атрибуты «\(node.source.path)»: \(String(cString: strerror(errno))).")
        }
        if previous != nil || request.localOptions?.preserveAllTimestamps == false {
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), node.stamp.modification]
            if request.localOptions?.preserveAllTimestamps == false { times[0].tv_nsec = Int(UTIME_NOW) }
            guard utimensat(AT_FDCWD, target.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard try TransferStamp(node.source) == (cleanupStamps[node.source] ?? node.stamp) else { throw TransferProblem("Источник изменился во время копирования: «\(node.source.path)».") }
    }

    func stageFilteredDescriptions(_ node: TransferNode, at target: URL) throws -> FilteredDescriptions? {
        let control = node.source.appendingPathComponent("descript.ion")
        guard try stampIfPresent(control)?.regular == true else { return nil }
        let key = FileDescriptionEncoding.directoryKey(node.source)
        let encoding = request.descriptionEncodings[key] ?? .utf8
        let source = try FileDescriptions.load(directory: node.source, encoding: encoding)
        let names = Set(node.children.map { $0.source.lastPathComponent })
        var destination = try FileDescriptions.load(directory: target, encoding: encoding)
        // If the filter copied the control file itself, preserve the formatting
        // of records for published children. Otherwise create only those records.
        for name in destination.descriptions.keys where !names.contains(name) {
            try destination.setDescription("", for: name)
        }
        for (name, description) in source.descriptions where names.contains(name) && destination.descriptions[name] == nil {
            try destination.setDescription(description, for: name)
        }
        try destination.save()
        try source.verifyCurrent()
        return FilteredDescriptions(source: source, publishedNames: names)
    }
    func copyBytes(from url: URL, expected: TransferStamp, to output: Int32, progress: (Int64) -> Void) throws {
        let input = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(input) }
        var opened = stat()
        guard fstat(input, &opened) == 0, opened.st_dev == expected.device, opened.st_ino == expected.inode else {
            throw TransferProblem("Файл был заменён перед чтением: «\(url.path)».")
        }
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var copied: Int64 = 0
        progress(copied)
        while true {
            try check()
            let count = read(input, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { break }
            var offset = 0
            try buffer.withUnsafeBytes { bytes in
                while offset < count {
                    try check()
                    let written = write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    guard written > 0 else { throw TransferProblem("Не удалось записать данные.") }
                    offset += written
                }
            }
            copied += Int64(count)
            progress(copied)
        }
        guard copied == expected.size, try TransferStamp(url) == (cleanupStamps[url] ?? expected) else {
            throw TransferProblem("Файл изменился при копировании: «\(url.path)».")
        }
    }
    /// Remove planned leaves only. Directory changes from our own removals are expected;
    /// new/unplanned children prevent rmdir and are retained. A retry can resume cleanup.
    func removePlannedSource(_ node: TransferNode, target: URL, receipt: TransferPublication, ancestors: [URL] = []) throws {
        try check()
        emit("Удаление источника", node.source)
        try check()
        for url in ancestors + [target] {
            guard let expected = receipt.stamps[receiptKey(url)], let actual = try stampIfPresent(url), actual == expected else {
                throw TransferProblem("Опубликованная копия отсутствует или изменилась; источник сохранён: «\(url.path)».")
            }
            if actual.directory { try verifyPublishedDescriptions(at: url, receipt: receipt) }
        }
        guard let current = try stampIfPresent(node.source) else { return }
        if node.stamp.directory {
            guard current.directory, current.sameObject(node.stamp) else {
                throw TransferProblem("Исходная папка была заменена; её содержимое сохранено: «\(node.source.path)».")
            }
            // Keep the original records available until every payload child has
            // been removed. Cancellation must not leave a remaining file without
            // the source control file that still describes it.
            let cleanupChildren: [TransferNode]
            if let descriptions = receipt.filteredDescriptions[node.source] {
                try descriptions.source.verifyCurrent()
                cleanupChildren = node.children.filter { $0.source.lastPathComponent != "descript.ion" }
            } else if request.propagateDescriptions {
                cleanupChildren = node.children.filter { $0.source.lastPathComponent != "descript.ion" }
                    + node.children.filter { $0.source.lastPathComponent == "descript.ion" }
            } else {
                cleanupChildren = node.children
            }
            for child in cleanupChildren {
                try removePlannedSource(child, target: target.appendingPathComponent(child.source.lastPathComponent),
                                        receipt: receipt, ancestors: ancestors + [target])
            }
            if node.hasExcludedChildren { return }
            guard let beforeRemoval = try stampIfPresent(node.source), beforeRemoval.directory,
                  beforeRemoval.sameObject(node.stamp) else {
                throw TransferProblem("Исходная папка была заменена перед удалением: «\(node.source.path)».")
            }
            guard rmdir(node.source.path) == 0 else {
                throw TransferProblem("Исходная папка содержит новые объекты или недоступна: «\(node.source.path)».")
            }
        } else {
            guard current == (cleanupStamps[node.source] ?? node.stamp) else {
                throw TransferProblem("Исходный объект изменился после копирования; он сохранён: «\(node.source.path)».")
            }
            guard unlink(node.source.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // Unlink changes ctime for other selected names of the same hard-linked inode.
            // Refresh only those names whose identity/content still match the copied snapshot.
            if node.stamp.links > 1 {
                for other in sourceLeaves where other.source != node.source && other.stamp.sameObject(node.stamp) {
                    if let remaining = try? TransferStamp(other.source), remaining.sameContentAfterRename(other.stamp) {
                        cleanupStamps[other.source] = remaining
                    }
                }
            }
        }
    }
    func leaves(_ node: TransferNode) -> [TransferNode] {
        node.stamp.directory ? node.children.flatMap { leaves($0) } : [node]
    }
    func verifyPublishedDescriptions(at target: URL, receipt: TransferPublication) throws {
        let control = target.appendingPathComponent("descript.ion")
        if let expected = receipt.stamps[receiptKey(control)], try stampIfPresent(control) != expected {
            throw TransferProblem("Опубликованные описания изменились; исходные описания сохранены: «\(control.path)».")
        }
    }
    func finishFilteredDescriptions(_ node: TransferNode, target: URL, receipt: TransferPublication) {
        guard node.stamp.directory else { return }
        if let descriptions = receipt.filteredDescriptions[node.source] {
            do {
                try verifyPublishedDescriptions(at: target, receipt: receipt)
                var source = descriptions.source
                for name in descriptions.publishedNames where source.descriptions[name] != nil {
                    if try stampIfPresent(node.source.appendingPathComponent(name)) == nil {
                        try source.setDescription("", for: name)
                    }
                }
                try source.save()
            } catch { descriptionWarning(error, source: node.source, target: target) }
        }
        for child in node.children where child.stamp.directory {
            finishFilteredDescriptions(child, target: target.appendingPathComponent(child.source.lastPathComponent), receipt: receipt)
        }
    }
    func removePublishedSource(_ node: TransferNode, target: URL, receipt: TransferPublication) throws {
        // Publication has succeeded. Retrying here must retry cleanup, never recopy data.
        while true {
            do {
                try removePlannedSource(node, target: target, receipt: receipt)
                if !receipt.filteredDescriptions.isEmpty { finishFilteredDescriptions(node, target: target, receipt: receipt) }
                return
            }
            catch is TransferStopped {
                issues.append("Копия сохранена в «\(target.path)». Удаление источника «\(node.source.path)» прервано; оставшиеся объекты сохранены.")
                throw TransferStopped()
            } catch {
                let message = "Копия сохранена, но источник удалён не полностью: «\(node.source.path)». \(error.localizedDescription)"
                switch failure(TransferFailure(source: node.source, destination: target, message: message)) {
                case .retry: continue
                case .skip: issues.append(message); failed += node.items; return
                case .cancel: issues.append(message); stopped = true; throw TransferStopped()
                }
            }
        }
    }
    // Only called for this worker's staging tree, never for source/destination trees.
    // Metadata may have made a staging directory read-only before an error occurred.
    func cleanupOwned(_ url: URL) {
        guard let stamp = try? TransferStamp(url) else { return }
        if stamp.directory {
            _ = chmod(url.path, 0o700)
            if let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                for child in children { cleanupOwned(child) }
            }
            _ = rmdir(url.path)
        } else { _ = unlink(url.path) }
    }
}
