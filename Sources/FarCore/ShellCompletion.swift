import Foundation
import Darwin

public enum ShellCompletionSource: String, Codable, CaseIterable, Sendable {
    case history, filesystem, environment, path
}

public enum ShellCompletionMode: Int, Codable, CaseIterable, Sendable {
    case disabled, automatic, manualOnly
}

public struct ShellCompletionSettings: Codable, Equatable, Sendable {
    public var automatic = true
    public var showList = true
    public var modalList = false
    public var appendFirst = false
    public var sources: [ShellCompletionSource: ShellCompletionMode] = [:]

    public init() {}

    public func isEnabled(_ source: ShellCompletionSource, manual: Bool) -> Bool {
        if !manual, !automatic { return false }
        switch sources[source] ?? .automatic {
        case .automatic: return true
        case .disabled: return false
        case .manualOnly: return manual
        }
    }
}

public struct ShellCompletionCandidate: Equatable, Sendable {
    public let source: ShellCompletionSource
    public let command: String
}

public struct ShellCompletion: Equatable, Sendable {
    public let candidates: [ShellCompletionCandidate]
    public let isTruncated: Bool
}

extension ShellCommand {
    public static func completeLine(_ command: String, currentDirectory: URL, history: [String],
                                    environment: [String: String], settings: ShellCompletionSettings = .init(),
                                    manual: Bool = false) throws -> ShellCompletion {
        try validate(command)
        guard !command.isEmpty || manual else { return .init(candidates: [], isTruncated: false) }
        let maximumResults = 100
        var candidates: [ShellCompletionCandidate] = [], seen: Set<String> = [command]
        var truncated = false
        func add(_ value: String, from source: ShellCompletionSource) {
            guard value.utf8.count <= maximumCommandBytes, !value.utf8.contains(0), seen.insert(value).inserted else { return }
            if candidates.count < maximumResults { candidates.append(.init(source: source, command: value)) }
            else { truncated = true }
        }
        if settings.isEnabled(.history, manual: manual), !command.isEmpty {
            for value in history where value.range(of: command, options: [.anchored, .caseInsensitive]) != nil {
                add(value, from: .history)
            }
        }
        guard let parsed = try? lex(command, allowIncomplete: true) else {
            return .init(candidates: candidates, isTruncated: truncated)
        }
        let token = parsed.endsInWhitespace ? nil : parsed.tokens.last
        let prefix = token.map { String(command[..<$0.start]) } ?? command
        let value = token?.value ?? ""
        let rawToken = token.map { String(command[$0.start...]) } ?? ""
        let bareToken = token?.isBare == true
        if settings.isEnabled(.filesystem, manual: manual), manual || !value.isEmpty {
            // A missing parent folder contributes no suggestions. Other sources
            // remain available, including when the local filesystem is unreadable.
            let expression = bareToken && !prefix.contains(where: { "|&;<>`$".contains($0) })
                ? environmentPath(rawToken, environment: environment) : nil
            let search = expression.map { try? quoteArgument($0.expanded) } ?? (parsed.unsupported ? nil : command)
            if let search, let files = try? completePath(in: search, currentDirectory: currentDirectory, caseInsensitive: true) {
                truncated = truncated || files.isTruncated
                let components = value.split(separator: "/", omittingEmptySubsequences: false)
                let pathPrefix = components.dropLast().joined(separator: "/") + (components.count > 1 ? "/" : "")
                for file in files.candidates {
                    let basename = (file.path as NSString).lastPathComponent + (file.isDirectory ? "/" : "")
                    let relative = pathPrefix + basename
                    let escaped: String
                    if let expression, relative.hasPrefix(expression.spelling) {
                        let suffix = try completionWord(String(relative.dropFirst(expression.spelling.count)))
                        if expression.spelling.hasPrefix("$") {
                            escaped = "\"" + expression.spelling.dropLast() + "\"/" + suffix
                        } else {
                            escaped = expression.spelling + suffix
                        }
                    } else if relative.hasPrefix("~/"), token?.leadingBareTilde == true {
                        escaped = "~/" + (try completionWord(String(relative.dropFirst(2))))
                    } else if value == "~", token?.leadingBareTilde == true {
                        escaped = "~/" + (try completionWord(basename))
                    } else {
                        let needsRelativePrefix = (prefix.isEmpty && !relative.contains("/")) || relative.hasPrefix("-")
                        escaped = try completionWord(needsRelativePrefix ? "./" + relative : relative)
                    }
                    add(prefix + escaped, from: .filesystem)
                }
            }
        }
        if settings.isEnabled(.environment, manual: manual), bareToken {
            let candidates = try environmentCandidates(rawToken, commandPrefix: prefix, environment: environment)
            for value in candidates { add(value, from: .environment) }
        }
        if settings.isEnabled(.path, manual: manual), !parsed.unsupported, !command.contains("/"), !value.isEmpty {
            let path = environment["PATH"] ?? environment.first(where: { $0.key.caseInsensitiveCompare("PATH") == .orderedSame })?.value ?? ""
            let modules = pathExecutables(matching: value, path: path, currentDirectory: currentDirectory)
            truncated = truncated || modules.isTruncated
            for name in modules.names { add(prefix + (try completionWord(name)), from: .path) }
        }
        return .init(candidates: candidates, isTruncated: truncated)
    }

    private static func completionWord(_ word: String) throws -> String {
        if !word.isEmpty, word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-./+".contains($0)) }) { return word }
        return try quoteArgument(word)
    }

    private static func environmentCandidates(_ token: String, commandPrefix: String,
                                              environment: [String: String]) throws -> [String] {
        let prefix: String, suffix: String
        if token.hasPrefix("${") { prefix = "${"; suffix = "}" }
        else if token.hasPrefix("$") { prefix = "$"; suffix = "" }
        else if token.hasPrefix("%") { prefix = "%"; suffix = "%" }
        else { return [] }
        let namePrefix = token.dropFirst(prefix.count)
        guard namePrefix.isEmpty || InternalCommandState.validShellName(String(namePrefix)) else { return [] }
        // Dollar-prefixed words inside compound syntax are ordinary shell
        // expressions and are outside this literal completion path.
        let parsedPrefix = try lex(commandPrefix, allowIncomplete: true)
        guard !parsedPrefix.unsupported else { return [] }
        return environment.keys.sorted().compactMap { name in
            guard InternalCommandState.validShellName(name), name.lowercased().hasPrefix(namePrefix.lowercased()) else { return nil }
            return commandPrefix + prefix + name + suffix
        }
    }

    private static func environmentPath(_ token: String, environment: [String: String]) -> (spelling: String, expanded: String)? {
        guard let slash = token.firstIndex(of: "/") else { return nil }
        let expression = token[..<slash]
        let name: Substring
        if expression.hasPrefix("${"), expression.hasSuffix("}") { name = expression.dropFirst(2).dropLast() }
        else if expression.hasPrefix("$") { name = expression.dropFirst() }
        else if expression.hasPrefix("%"), expression.hasSuffix("%") { name = expression.dropFirst().dropLast() }
        else { return nil }
        guard InternalCommandState.validShellName(String(name)),
              let root = environment[String(name)], !root.isEmpty, !root.utf8.contains(0) else { return nil }
        let expanded = root + token[slash...]
        return (String(expression) + "/", expanded)
    }

    private static func pathExecutables(matching prefix: String, path: String,
                                        currentDirectory: URL) -> (names: [String], isTruncated: Bool) {
        let directories = path.split(separator: ":", omittingEmptySubsequences: false)
        guard !path.isEmpty else { return ([], false) }
        let lower = prefix.lowercased()
        var names = Set<String>(), scannedDirectories = Set<URL>(), scanned = 0
        for component in directories.prefix(128) {
            let directory: URL
            if component.hasPrefix("/") { directory = URL(fileURLWithPath: String(component), isDirectory: true) }
            else { directory = currentDirectory.appendingPathComponent(String(component), isDirectory: true) }
            guard scannedDirectories.insert(directory.standardizedFileURL).inserted,
                  let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [],
                     options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { continue }
            for case let candidate as URL in enumerator {
                guard scanned < 4096 else { return (names.sorted(), true) }
                scanned += 1
                let name = candidate.lastPathComponent
                guard name.lowercased().hasPrefix(lower), access(candidate.path, X_OK) == 0 else { continue }
                var info = stat()
                if stat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { names.insert(name) }
            }
        }
        return (names.sorted(), directories.count > 128)
    }
}
