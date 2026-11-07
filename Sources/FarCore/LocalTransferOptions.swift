import Darwin
import Foundation

public enum LocalTransferConflictPolicy: String, CaseIterable, Codable, Sendable {
    case ask, overwrite, skip, rename, append, newer
}

public struct LocalTransferDestination: Hashable, Sendable {
    public let url: URL
    public let forceDirectory: Bool

    private struct Identity: Hashable {
        let device: dev_t
        let directory: ino_t
        let relativePath: String
    }

    public static func parse(_ input: String, relativeTo base: URL, multiple: Bool) throws -> [Self] {
        var paths: [String] = []
        var part = ""
        var quoted = false
        for character in input {
            if multiple && character == "\"" {
                quoted.toggle()
                part.append(character)
            } else if multiple && !quoted && (character == ";" || character == ",") {
                paths.append(part)
                part = ""
            } else {
                part.append(character)
            }
        }
        guard !quoted else { throw LocalTransferInputError("Закройте кавычки в списке назначений.") }
        paths.append(part)
        guard paths.count <= 100 else { throw LocalTransferInputError("Допускается до 100 назначений.") }
        var result: [Self] = []
        var seen = Set<Identity>()
        for var path in paths {
            if multiple { path = path.trimmingCharacters(in: .whitespacesAndNewlines) }
            if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
                path.removeFirst()
                path.removeLast()
            }
            if multiple && path.contains("\"") { throw LocalTransferInputError("Заключите путь целиком в кавычки.") }
            guard !path.isEmpty, !path.contains("\0") else { throw LocalTransferInputError("Укажите непустой путь назначения.") }
            let forceDirectory = path.hasSuffix("/")
            path = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path.hasPrefix("/") ? path : base.path + "/" + path).standardizedFileURL
            let name = url.lastPathComponent
            let hasMask = name.contains("*") || name.contains("?")
            let parent = url.deletingLastPathComponent().path
            guard !parent.contains("*"), !parent.contains("?"), !(forceDirectory && hasMask) else {
                throw LocalTransferInputError("Маска допустима только в конечном имени назначения.")
            }
            if paths.count > 1 {
                guard let identity = identity(of: url), seen.insert(identity).inserted else {
                    throw LocalTransferInputError("Назначение указано несколько раз или недоступно: «\(url.path)».")
                }
            }
            result.append(Self(url: url, forceDirectory: forceDirectory))
        }
        return result
    }

    public static func validateDistinctTargets(_ destinations: [Self], sources: [URL]) throws {
        guard destinations.count > 1 else { return }
        var seen = Set<Identity>()
        for destination in destinations {
            let layout = try LocalTransferLayout(destination: destination.url, sourceCount: sources.count,
                                                 forceDirectory: destination.forceDirectory, permitMask: true)
            for source in sources {
                let target = try layout.target(for: source)
                guard let identity = identity(of: target, resolveFinalDirectory: false), seen.insert(identity).inserted else {
                    throw LocalTransferInputError("Несколько назначений записывают один и тот же путь: «\(target.path)».")
                }
            }
        }
    }

    /// Match existing directory aliases and paths beneath aliased parents while
    /// keeping the user's original URL for the worker's path checks and writes.
    private static func identity(of url: URL, resolveFinalDirectory: Bool = true) -> Identity? {
        var directory = resolveFinalDirectory ? url : url.deletingLastPathComponent()
        var suffix: [String] = resolveFinalDirectory ? [] : [url.lastPathComponent]
        while true {
            var info = stat()
            if stat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                var name = suffix.reversed().joined(separator: "/").precomposedStringWithCanonicalMapping
                let volume = try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                if volume?.volumeSupportsCaseSensitiveNames == false {
                    name = name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                }
                return Identity(device: info.st_dev, directory: info.st_ino, relativePath: name)
            }
            guard directory.path != "/" else { return nil }
            suffix.append(directory.lastPathComponent)
            directory.deleteLastPathComponent()
        }
    }

    public static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.path == rhs.path { return true }
        guard let left = identity(of: lhs), let right = identity(of: rhs) else { return false }
        return left.relativePath.isEmpty && left == right
    }
}

struct LocalTransferLayout {
    let parent: URL
    private let destination: URL
    private let directory: Bool
    private let mask: FilenameRenameMask?

    init(destination: URL, sourceCount: Int, forceDirectory: Bool, permitMask: Bool) throws {
        let destination = destination.standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        let directory = exists && isDirectory.boolValue || forceDirectory
        let name = destination.lastPathComponent
        let mask = permitMask && !directory && (name.contains("*") || name.contains("?")) ? try FilenameRenameMask(name) : nil
        guard !(directory && exists && !isDirectory.boolValue) else {
            throw LocalTransferInputError("Назначение должно быть папкой: «\(destination.path)».")
        }
        guard directory || mask != nil || sourceCount == 1 else {
            throw LocalTransferInputError("Для нескольких источников назначение должно быть существующей папкой.")
        }
        self.destination = destination
        self.directory = directory
        self.mask = mask
        parent = directory ? destination : destination.deletingLastPathComponent()
    }

    func target(for source: URL) throws -> URL {
        if directory { return destination.appendingPathComponent(source.lastPathComponent) }
        if let mask {
            let name = try mask.destinationName(for: source.lastPathComponent)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                throw LocalTransferInputError("Недопустимое новое имя: «\(name)».")
            }
            return parent.appendingPathComponent(name)
        }
        return destination
    }
}

public struct LocalTransferFilterRule: Codable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable {
        case include = "+", exclude = "-", priorityInclude = "I", priorityExclude = "X"
        var includes: Bool { self == .include || self == .priorityInclude }
        var priority: Bool { self == .priorityInclude || self == .priorityExclude }
    }
    public enum Scope: String, Codable, CaseIterable, Sendable { case files, directories, all }
    public enum TimeField: String, Codable, CaseIterable, Sendable { case modified, created, accessed, changed }
    public struct Attribute: OptionSet, Codable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let readOnly = Self(rawValue: 1 << 0)
        public static let hidden = Self(rawValue: 1 << 1)
        public static let symbolicLink = Self(rawValue: 1 << 2)
    }
    public var title: String
    public var action: Action
    public var scope: Scope
    public var mask: String
    public var minBytes: Int64?
    public var maxBytes: Int64?
    public var timeField: TimeField
    public var earliest: Date?
    public var latest: Date?
    public var required: Attribute
    public var forbidden: Attribute

    public init(title: String = "", action: Action = .include, scope: Scope = .files, mask: String = "*",
                minBytes: Int64? = nil, maxBytes: Int64? = nil, timeField: TimeField = .modified,
                earliest: Date? = nil, latest: Date? = nil, required: Attribute = [], forbidden: Attribute = []) {
        self.title = title; self.action = action; self.scope = scope; self.mask = mask
        self.minBytes = minBytes; self.maxBytes = maxBytes; self.timeField = timeField
        self.earliest = earliest; self.latest = latest; self.required = required; self.forbidden = forbidden
    }

    public static func parseSize(_ value: String) throws -> Int64? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let suffix = text.last!
        let suffixes: [Character: Int] = ["B": 0, "K": 1, "M": 2, "G": 3, "T": 4, "P": 5, "E": 6]
        let upper = String(suffix).uppercased()
        var multiplier: Int64 = 1
        if upper.count == 1, let power = suffixes[upper.first!] {
            text.removeLast()
            for _ in 0..<power { multiplier *= String(suffix) == upper ? 1024 : 1000 }
        }
        guard let size = Int64(text), size >= 0, size <= Int64.max / multiplier else {
            throw LocalTransferInputError("Некорректный размер: «\(value)». Пример: 1K или 500.")
        }
        return size * multiplier
    }
}

public struct LocalTransferOptions: Codable, Equatable, Sendable {
    public var forceDirectory: Bool
    public var conflictPolicy: LocalTransferConflictPolicy
    public var confirmReadOnly: Bool
    public var preserveAllTimestamps: Bool
    public var filterRules: [LocalTransferFilterRule]
    public var maskGroups: [String: String]

    public init(forceDirectory: Bool = false, conflictPolicy: LocalTransferConflictPolicy = .ask,
                confirmReadOnly: Bool = true, preserveAllTimestamps: Bool = true,
                filterRules: [LocalTransferFilterRule] = [], maskGroups: [String: String] = [:]) {
        self.forceDirectory = forceDirectory; self.conflictPolicy = conflictPolicy
        self.confirmReadOnly = confirmReadOnly; self.preserveAllTimestamps = preserveAllTimestamps
        self.filterRules = filterRules; self.maskGroups = maskGroups
    }

    public func validateFilter() throws { _ = try LocalTransferFilter(filterRules, groups: maskGroups) }
}

struct LocalTransferInputError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

struct LocalTransferFilter {
    private let rules: [(LocalTransferFilterRule, FileMask?)]
    var isEmpty: Bool { rules.isEmpty }

    init(_ rules: [LocalTransferFilterRule], groups: [String: String]) throws {
        guard rules.count <= 100 else { throw LocalTransferInputError("Допускается до 100 правил фильтра.") }
        self.rules = try rules.map { rule in
            guard rule.minBytes ?? 0 >= 0, rule.maxBytes ?? .max >= rule.minBytes ?? 0,
                  rule.earliest ?? .distantPast <= rule.latest ?? .distantFuture,
                  rule.required.intersection(rule.forbidden).isEmpty else {
                throw LocalTransferInputError("Противоречивые границы или атрибуты фильтра «\(rule.title)».")
            }
            return (rule, rule.mask.isEmpty ? nil : try FileMask(rule.mask, groups: groups))
        }
    }

    func allows(name: String, info: stat) throws -> Bool {
        let directory = info.st_mode & S_IFMT == S_IFDIR
        var attributes: LocalTransferFilterRule.Attribute = []
        if info.st_mode & S_IWUSR == 0 { attributes.insert(.readOnly) }
        if name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0 { attributes.insert(.hidden) }
        if info.st_mode & S_IFMT == S_IFLNK { attributes.insert(.symbolicLink) }
        var firstMatch: Bool?
        var hasInclude = false
        var hasFolderInclude = false
        for (rule, mask) in rules {
            if firstMatch != nil && !rule.action.priority { continue }
            if rule.action.includes {
                hasInclude = true
                hasFolderInclude = hasFolderInclude || rule.scope != .files
            }
            if directory && rule.scope == .files || !directory && rule.scope == .directories { continue }
            guard info.st_size >= rule.minBytes ?? 0, info.st_size <= rule.maxBytes ?? .max,
                  attributes.isSuperset(of: rule.required), attributes.intersection(rule.forbidden).isEmpty else { continue }
            let timestamp: timespec
            switch rule.timeField {
            case .modified: timestamp = info.st_mtimespec
            case .created: timestamp = info.st_birthtimespec
            case .accessed: timestamp = info.st_atimespec
            case .changed: timestamp = info.st_ctimespec
            }
            let date = Date(timeIntervalSince1970: Double(timestamp.tv_sec) + Double(timestamp.tv_nsec) / 1e9)
            if let earliest = rule.earliest, date < earliest { continue }
            if let latest = rule.latest, date > latest { continue }
            if let mask, try !mask.matchesChecked(name) { continue }
            if rule.action.priority { return rule.action.includes }
            firstMatch = rule.action.includes
        }
        return firstMatch ?? (directory ? !hasFolderInclude : !hasInclude)
    }
}
