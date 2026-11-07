import Foundation

public enum FileCaseMode: Int, CaseIterable, Codable, Sendable {
    case lower, upper, first, title, unchanged
}

public struct FileCaseOptions: Codable, Equatable, Sendable {
    public static let defaultWordDelimiters = " _"
    public var name: FileCaseMode
    public var fileExtension: FileCaseMode
    public var skipMixedCase: Bool
    public var recurse: Bool
    public var renameDirectories: Bool
    public var wordDelimiters: String

    public init(name: FileCaseMode = .lower, fileExtension: FileCaseMode = .lower, skipMixedCase: Bool = true,
                recurse: Bool = false, renameDirectories: Bool = false, wordDelimiters: String = Self.defaultWordDelimiters) {
        self.name = name
        self.fileExtension = fileExtension
        self.skipMixedCase = skipMixedCase
        self.recurse = recurse
        self.renameDirectories = renameDirectories
        self.wordDelimiters = wordDelimiters
    }
}

public enum FileCase {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// FAR splits each selected name at the final dot, including folder names.
    /// On macOS the dot is kept even when it is a legal trailing character.
    public static func convertedName(_ name: String, isDirectory: Bool, options: FileCaseOptions) -> String {
        guard name != ".", name != "..", !isDirectory || options.renameDirectories else { return name }
        guard let dot = name.lastIndex(of: ".") else { return convert(name, mode: options.name, options: options) }
        let stem = String(name[..<dot])
        let suffix = String(name[name.index(after: dot)...])
        return convert(stem, mode: options.name, options: options) + "." + convert(suffix, mode: options.fileExtension, options: options)
    }

    private static func convert(_ text: String, mode: FileCaseMode, options: FileCaseOptions) -> String {
        guard !text.isEmpty, mode != .unchanged, !options.skipMixedCase || !isMixed(text) else { return text }
        switch mode {
        case .lower: return text.lowercased()
        case .upper: return text.uppercased()
        case .first: return text.prefix(1).uppercased() + text.dropFirst().lowercased()
        case .title:
            let delimiters = Set(options.wordDelimiters.unicodeScalars)
            var first = true
            var result = ""
            for scalar in text.unicodeScalars {
                let letter = String(scalar)
                result += first ? letter.uppercased() : letter.lowercased()
                first = delimiters.contains(scalar)
            }
            return result
        case .unchanged: return text
        }
    }

    private static func isMixed(_ text: String) -> Bool {
        var firstLower: Bool?
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            let lower = scalar.properties.isLowercase
            if let firstLower, lower != firstLower { return true }
            firstLower = lower
        }
        return false
    }

    /// Prepare all siblings before mutating. Apply deeper directories first so
    /// renaming a parent cannot invalidate the captured paths of its children.
    @discardableResult
    public static func rename(_ urls: [URL], options: FileCaseOptions, cancellation: FileToolCancellation = .init()) throws -> Int {
        guard options.name != .unchanged || options.fileExtension != .unchanged else { return 0 }
        guard options.wordDelimiters.utf16.count <= 511 else { throw Failure("FileCase: список разделителей длиннее 511 символов.") }
        let roots = try FileTools.snapshot(urls)
        var groups: [String: [BatchRenameEntry]] = [:]
        var count = 0
        func collect(_ item: FileToolItem) throws {
            if cancellation.isCancelled { throw CancellationError() }
            count += 1
            guard count <= 100_000 else { throw Failure("FileCase: больше 100 000 объектов.") }
            let name = item.url.lastPathComponent
            let converted = convertedName(name, isDirectory: item.isDirectory, options: options)
            guard !converted.utf8.elementsEqual(name.utf8) else { return }
            let parent = item.url.deletingLastPathComponent()
            groups[parent.path, default: []].append(BatchRenameEntry(source: item, destination: parent.appendingPathComponent(converted)))
        }
        for root in roots {
            try collect(root)
            guard options.recurse, root.isDirectory else { continue }
            var readError: Error?
            // Foundation's URL enumerator never traverses directory symlinks.
            guard let children = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: nil, options: [],
                errorHandler: { _, error in readError = error; return false }) else {
                throw Failure("FileCase: не удалось прочитать папку «\(root.url.path)».")
            }
            while let child = children.nextObject() as? URL {
                if cancellation.isCancelled { throw CancellationError() }
                try collect(FileTools.metadata(child))
            }
            if let readError { throw readError }
        }
        let order = groups.keys.sorted { left, right in
            let a = left.utf8.reduce(0) { $0 + ($1 == 47 ? 1 : 0) }
            let b = right.utf8.reduce(0) { $0 + ($1 == 47 ? 1 : 0) }
            return a == b ? left < right : a > b
        }
        for key in order {
            if cancellation.isCancelled { throw CancellationError() }
            if let entries = groups[key] { try FileTools.validateRename(entries, allowCaseOnly: true) }
        }
        var completed = 0
        for key in order {
            guard let entries = groups[key] else { continue }
            do {
                if cancellation.isCancelled { throw CancellationError() }
                completed += try FileTools.executeRename(entries, propagateDescriptions: false, allowCaseOnly: true)
            } catch {
                if completed == 0 { throw error }
                throw Failure("FileCase: переименовано в предыдущих папках \(completed). \(error.localizedDescription)")
            }
        }
        return completed
    }
}
