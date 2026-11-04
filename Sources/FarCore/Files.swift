import Foundation

public struct FileEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let modified: Date?
    public let created: Date?
    public let accessed: Date?
    public let permissions: String
    public let owner: String

    public init(
        url: URL, name: String, isDirectory: Bool, isSymbolicLink: Bool,
        size: Int64, modified: Date?, created: Date? = nil, accessed: Date? = nil,
        permissions: String = "", owner: String = ""
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modified = modified
        self.created = created
        self.accessed = accessed
        self.permissions = permissions
        self.owner = owner
    }
}

public enum FileSort: String, CaseIterable, Codable, Sendable {
    case name, size, modified, `extension`, created, accessed, selected
}

public struct FileSortOptions: Codable, Equatable, Sendable {
    public var sort: FileSort
    public var ascending: Bool
    public var directoriesFirst: Bool
    public var caseSensitive: Bool
    public var naturalOrder: Bool

    public init(
        sort: FileSort = .name, ascending: Bool = true, directoriesFirst: Bool = true,
        caseSensitive: Bool = false, naturalOrder: Bool = true
    ) {
        self.sort = sort
        self.ascending = ascending
        self.directoriesFirst = directoriesFirst
        self.caseSensitive = caseSensitive
        self.naturalOrder = naturalOrder
    }
}

public enum FileService {
    public static func list(
        _ directory: URL,
        showHidden: Bool,
        sort: FileSort = .name,
        ascending: Bool = true,
        sortResult: Bool = true
    ) throws -> [FileEntry] {
        try validateDirectory(directory)
        let manager = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        do {
            let entries = try manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: options
            ).map { url -> FileEntry in
                let attributes = try manager.attributesOfItem(atPath: url.path)
                let isLink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
                let targetAttributes = isLink
                    ? (try? manager.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))
                    : nil
                let displayAttributes = targetAttributes ?? attributes
                let dates = try? url.resourceValues(forKeys: [.creationDateKey, .contentAccessDateKey])
                return FileEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: displayAttributes[.type] as? FileAttributeType == .typeDirectory,
                    isSymbolicLink: isLink,
                    size: (displayAttributes[.size] as? NSNumber)?.int64Value ?? 0,
                    modified: displayAttributes[.modificationDate] as? Date,
                    created: dates?.creationDate ?? displayAttributes[.creationDate] as? Date,
                    accessed: dates?.contentAccessDate,
                    permissions: symbolicPermissions(attributes),
                    owner: attributes[.ownerAccountName] as? String
                        ?? (attributes[.ownerAccountID] as? NSNumber)?.stringValue ?? ""
                )
            }
            return sortResult ? sorted(entries, options: FileSortOptions(sort: sort, ascending: ascending)) : entries
        } catch {
            throw OperationError("Не удалось прочитать каталог «\(directory.path)»: \(error.localizedDescription)")
        }
    }

    public static func sorted(
        _ entries: [FileEntry], options: FileSortOptions, markedIDs: Set<String> = []
    ) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            // Directory placement stays stable when the requested order is reversed.
            if options.directoriesFirst && lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison: ComparisonResult
            switch options.sort {
            case .name:
                comparison = compareNames(lhs.name, rhs.name, options: options)
            case .size:
                comparison = compare(lhs.size, rhs.size)
            case .modified:
                comparison = compare(lhs.modified ?? .distantPast, rhs.modified ?? .distantPast)
            case .extension:
                let left = lhs.url.pathExtension
                let right = rhs.url.pathExtension
                comparison = compareNames(
                    options.caseSensitive ? left : left.folding(options: .caseInsensitive, locale: .current),
                    options.caseSensitive ? right : right.folding(options: .caseInsensitive, locale: .current),
                    options: options
                )
            case .created:
                comparison = compare(lhs.created ?? .distantPast, rhs.created ?? .distantPast)
            case .accessed:
                comparison = compare(lhs.accessed ?? .distantPast, rhs.accessed ?? .distantPast)
            case .selected:
                comparison = compare(markedIDs.contains(lhs.id) ? 0 : 1, markedIDs.contains(rhs.id) ? 0 : 1)
            }
            let byName = comparison == .orderedSame
                ? compareNames(lhs.name, rhs.name, options: options) : comparison
            let resolved = byName == .orderedSame ? lhs.id.compare(rhs.id) : byName
            return options.ascending ? resolved == .orderedAscending : resolved == .orderedDescending
        }
    }

    public static func createDirectory(named name: String, in directory: URL) throws {
        try validateName(name)
        try validateDirectory(directory)
        let target = directory.appendingPathComponent(name, isDirectory: true)
        try requireAbsent(target)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch {
            throw OperationError("Не удалось создать папку «\(name)»: \(error.localizedDescription)")
        }
    }

    public static func rename(_ source: URL, to name: String) throws {
        try validateName(name)
        _ = try checkedSources([source])
        guard source.standardizedFileURL.path != "/" else {
            throw OperationError("Корневой каталог нельзя переименовать.")
        }
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        guard entryIdentity(source) != entryIdentity(target) else {
            throw OperationError("Новое имя совпадает с текущим: «\(name)».")
        }
        try requireAbsent(target)
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            throw OperationError("Не удалось переименовать «\(source.lastPathComponent)»: \(error.localizedDescription)")
        }
    }

    public static func transfer(_ sources: [URL], to directory: URL, move: Bool) throws {
        guard !sources.isEmpty else { return }
        try validateDirectory(directory)
        let items = try checkedSources(sources)
        let destinationDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let caseSensitiveNames = (try? destinationDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? true
        var destinations = Set<String>()
        let transfers = try items.map { item -> (source: URL, target: URL) in
            let target = directory.appendingPathComponent(item.url.lastPathComponent)
            let targetIdentity = entryIdentity(target)
            guard item.identity != targetIdentity else {
                throw OperationError("Источник и назначение совпадают: «\(item.url.path)».")
            }
            let destinationName = item.url.lastPathComponent.precomposedStringWithCanonicalMapping
            let collisionKey = caseSensitiveNames ? destinationName : destinationName.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard destinations.insert(collisionKey).inserted else {
                throw OperationError("Несколько выбранных объектов имеют одинаковое имя «\(item.url.lastPathComponent)».")
            }
            if item.isDirectory && contains(destinationDirectory.path, in: item.identity) {
                throw OperationError("Нельзя поместить папку «\(item.url.lastPathComponent)» внутрь неё самой.")
            }
            try requireAbsent(target)
            return (item.url, target)
        }

        var completed = 0
        for transfer in transfers {
            do {
                if move {
                    try FileManager.default.moveItem(at: transfer.source, to: transfer.target)
                } else {
                    try FileManager.default.copyItem(at: transfer.source, to: transfer.target)
                }
                completed += 1
            } catch {
                let action = move ? "переместить" : "скопировать"
                throw OperationError(
                    "Не удалось \(action) «\(transfer.source.lastPathComponent)»: \(error.localizedDescription). " +
                    "Успешно обработано: \(completed) из \(transfers.count). " +
                    "В назначении могут остаться частично записанные данные; автоматический откат не выполнялся."
                )
            }
        }
    }

    public static func trash(_ urls: [URL]) throws {
        let items = try checkedSources(urls)
        var completed = 0
        for item in items {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                completed += 1
            } catch {
                throw OperationError(
                    "Не удалось отправить «\(item.url.lastPathComponent)» в Корзину: \(error.localizedDescription). " +
                    "Успешно обработано: \(completed) из \(items.count)."
                )
            }
        }
    }

    private struct Source {
        let url: URL
        let identity: String
        let isDirectory: Bool
    }

    private static func checkedSources(_ urls: [URL]) throws -> [Source] {
        var identities = Set<String>()
        let items = try urls.map { url -> Source in
            try validateFileURL(url)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch {
                throw OperationError("Не удалось открыть источник «\(url.path)»: \(error.localizedDescription)")
            }
            let identity = entryIdentity(url)
            guard identities.insert(identity).inserted else {
                throw OperationError("Один объект выбран несколько раз: «\(url.path)».")
            }
            return Source(url: url, identity: identity, isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory)
        }
        for parent in items where parent.isDirectory {
            if let child = items.first(where: { $0.identity != parent.identity && contains($0.identity, in: parent.identity) }) {
                throw OperationError("Выбраны и папка «\(parent.url.lastPathComponent)», и вложенный объект «\(child.url.lastPathComponent)». Выполните операции отдельно.")
            }
        }
        return items
    }

    private static func validateDirectory(_ url: URL) throws {
        try validateFileURL(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OperationError("Каталог недоступен или не существует: «\(url.path)».")
        }
    }

    private static func validateFileURL(_ url: URL) throws {
        guard url.isFileURL else { throw OperationError("Поддерживаются только локальные файлы: «\(url.absoluteString)».") }
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw OperationError("Недопустимое имя. Укажите непустое имя без «/», «.» и «..».")
        }
    }

    private static func requireAbsent(_ url: URL) throws {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError) {
                return
            }
            throw OperationError("Не удалось проверить назначение «\(url.path)»: \(error.localizedDescription)")
        }
        throw OperationError("Объект «\(url.lastPathComponent)» уже существует в назначении. Перезапись запрещена.")
    }

    // Resolve parent aliases, while keeping the final symbolic link as the selected object.
    private static func entryIdentity(_ url: URL) -> String {
        let normalized = url.standardizedFileURL
        return normalized.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(normalized.lastPathComponent).standardizedFileURL.path
    }

    private static func contains(_ path: String, in ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    private static func compareNames(_ lhs: String, _ rhs: String, options: FileSortOptions) -> ComparisonResult {
        let comparison: ComparisonResult
        if options.naturalOrder && !options.caseSensitive {
            comparison = lhs.localizedStandardCompare(rhs)
        } else {
            var flags: String.CompareOptions = []
            if options.naturalOrder { flags.insert(.numeric) }
            if !options.caseSensitive { flags.insert(.caseInsensitive) }
            comparison = lhs.compare(rhs, options: flags)
        }
        return comparison == .orderedSame ? lhs.compare(rhs, options: .literal) : comparison
    }

    private static func symbolicPermissions(_ attributes: [FileAttributeKey: Any]) -> String {
        guard let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue else { return "" }
        let type: String
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory: type = "d"
        case .typeSymbolicLink: type = "l"
        case .typeBlockSpecial: type = "b"
        case .typeCharacterSpecial: type = "c"
        case .typeSocket: type = "s"
        case .typeUnknown: type = "?"
        default: type = "-"
        }
        var result = type
        for (read, write, execute, special, lower, upper) in [
            (0o400, 0o200, 0o100, 0o4000, "s", "S"),
            (0o040, 0o020, 0o010, 0o2000, "s", "S"),
            (0o004, 0o002, 0o001, 0o1000, "t", "T")
        ] {
            result += mode & read != 0 ? "r" : "-"
            result += mode & write != 0 ? "w" : "-"
            result += mode & special != 0 ? (mode & execute != 0 ? lower : upper) : (mode & execute != 0 ? "x" : "-")
        }
        return result
    }

    private struct OperationError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
