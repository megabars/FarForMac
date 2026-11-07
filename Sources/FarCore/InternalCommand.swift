import Foundation
import Darwin

public enum InternalFarCommand: Equatable, Sendable {
    case config, about, regex, log(String), error(UInt32)
}

public enum InternalDirectoryStackChange: Equatable, Sendable {
    case push(URL), pop
}

public enum InternalCommandAction: Equatable, Sendable {
    case shell(String)
    case skip
    case directory(URL, closeProvider: Bool, stack: InternalDirectoryStackChange?)
    case output(String)
    case clearScreen
    case title(String?)
    case exit(Int32)
    case far(InternalFarCommand)
    case plugin(prefix: String, arguments: String)
}

public struct InternalCommandDispatch: Equatable, Sendable {
    public let command: String
    public let echo: Bool
    public let action: InternalCommandAction
}

/// The environment belongs to a workspace and is inherited by its child shells.
public struct InternalCommandState: Sendable {
    private let baseEnvironment: [String: String]
    public private(set) var environmentOverrides: [String: String] = [:]
    public private(set) var environmentRemovals: Set<String> = []
    public private(set) var directoryStack: [URL] = []

    public init(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.baseEnvironment = baseEnvironment
    }

    public var environment: [String: String] {
        var result = baseEnvironment
        for key in environmentRemovals { result.removeValue(forKey: key) }
        result.merge(environmentOverrides) { _, new in new }
        return result
    }

    public func environmentValue(_ name: String) -> String? {
        if let exact = environmentOverrides[name] { return exact }
        if let override = environmentOverrides.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) { return override.value }
        if environmentRemovals.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return nil }
        return baseEnvironment[name] ?? baseEnvironment.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    public mutating func commit(_ stack: InternalDirectoryStackChange) {
        switch stack {
        case .push(let directory): directoryStack.append(directory)
        case .pop: _ = directoryStack.popLast()
        }
        setEnvironment("FARDIRSTACK", value: directoryStack.last?.path)
    }

    /// Strips the FAR conditions without executing or changing the workspace.
    public func conditionallyExecutable(_ source: String, currentDirectory: URL) throws -> String? {
        try ShellCommand.validate(source)
        var command = source[...]
        var evaluated = false
        skipEchoPrefix(in: &command)
        while let parsed = Self.condition(in: command) {
            let operand = parsed.expandPercent ? expandEnvironment(parsed.operand) : parsed.operand
            if parsed.exists {
                guard !operand.isEmpty, !operand.utf8.contains(0), currentDirectory.isFileURL else { return nil }
                let path = try ShellCommand.resolve(operand, bareTilde: parsed.bareTilde,
                    currentDirectory: currentDirectory, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
                let exists = try FileManager.default.fileExists(atPath: path.path) ||
                    (parsed.wildcard && Self.matchesExistingFilename(path))
                if exists == parsed.negated { return nil }
            } else if (environmentValue(operand) != nil) == parsed.negated {
                return nil
            }
            command = parsed.remainder
            evaluated = true
        }
        if !evaluated { return source }
        let echoPrefix = source.trimmingCharacters(in: .whitespaces).prefix(while: { $0 == "@" })
        return String(echoPrefix) + String(command)
    }

    public mutating func dispatch(_ source: String, currentDirectory: URL, previousDirectory: URL? = nil) throws -> InternalCommandDispatch {
        var original = source[...]
        let initialEcho = !skipEchoPrefix(in: &original)
        guard let conditioned = try conditionallyExecutable(source, currentDirectory: currentDirectory) else {
            return .init(command: "", echo: initialEcho, action: .skip)
        }
        var remaining = conditioned[...]
        let echo = !skipEchoPrefix(in: &remaining)
        let command = String(remaining)
        func result(_ action: InternalCommandAction) -> InternalCommandDispatch {
            .init(command: command, echo: echo, action: action)
        }
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return result(.skip) }
        if let far = Self.farCommand(trimmed) { return result(.far(far)) }
        if let colon = trimmed.firstIndex(of: ":") {
            let prefix = trimmed[..<colon]
            if prefix.count > 1, prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
                return result(.plugin(prefix: prefix.lowercased(), arguments: String(trimmed[trimmed.index(after: colon)...])))
            }
        }

        let keyword = trimmed.prefix(while: { !$0.isWhitespace }).lowercased()
        let arguments = trimmed.dropFirst(keyword.count).drop(while: { $0.isWhitespace })
        if arguments == "/?" || arguments.hasPrefix("/? ") { return result(.shell(command)) }
        let argumentText = String(arguments)
        switch keyword {
        case "cd", "chdir", "pushd":
            if keyword == "pushd", arguments.isEmpty {
                commit(.push(currentDirectory))
                return result(.skip)
            }
            // FAR percent variables are expanded as literal path data. POSIX
            // expressions are only evaluated by the external shell.
            let normalized = keyword == "pushd" ? "cd " + argumentText : trimmed
            if let destination = try ShellCommand.directoryChange(in: normalized, currentDirectory: currentDirectory,
                previousDirectory: previousDirectory, expandPath: expandEnvironment) {
                return result(.directory(destination, closeProvider: keyword != "cd", stack: keyword == "pushd" ? .push(currentDirectory) : nil))
            }
        case "popd" where arguments.isEmpty:
            guard let destination = directoryStack.last else { return result(.skip) }
            // The FAR source pops even if navigation fails.
            commit(.pop)
            return result(.directory(destination, closeProvider: true, stack: nil))
        case "clrd" where arguments.isEmpty:
            directoryStack.removeAll()
            setEnvironment("FARDIRSTACK", value: nil)
            return result(.skip)
        case "cls" where arguments.isEmpty:
            return result(.clearScreen)
        case "title":
            guard try !ShellCommand.lex(trimmed, allowIncomplete: false).unsupported else { break }
            return result(.title(arguments.isEmpty ? nil : argumentText))
        case "exit":
            if arguments.isEmpty { return result(.exit(0)) }
            if let code = Int32(arguments) { return result(.exit(code)) }
        case "set":
            if let action = try setCommand(argumentText) { return result(action) }
        default:
            break
        }
        return result(.shell(command))
    }

    private mutating func setCommand(_ argument: String) throws -> InternalCommandAction? {
        if let option = argument.split(whereSeparator: \.isWhitespace).first?.lowercased(), ["/a", "/p"].contains(option) {
            return nil
        }
        guard try !ShellCommand.lex(argument, allowIncomplete: false).unsupported else { return nil }
        let content: Substring
        if argument.first == "\"", let lastQuote = argument.lastIndex(of: "\""), lastQuote > argument.startIndex {
            content = argument[argument.index(after: argument.startIndex)..<lastQuote].drop(while: { $0.isWhitespace })
        } else {
            content = argument[...]
        }
        if let equal = content.firstIndex(of: "="), equal > content.startIndex {
            let name = String(content[..<equal])
            guard Self.validShellName(name) else { return nil }
            let value = String(content[content.index(after: equal)...])
            setEnvironment(name, value: value.isEmpty ? nil : expandEnvironment(value))
            return .skip
        }
        let environment = environment
        let prefix = content.lowercased()
        let lines = environment.keys.sorted().filter { $0.lowercased().hasPrefix(prefix) }.map { "\($0)=\(environment[$0] ?? "")" }
        return .output(lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
    }

    public static func validShellName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    public mutating func setEnvironment(_ name: String, value: String?) {
        let aliases = Set(baseEnvironment.keys).union(environmentOverrides.keys).filter { $0.caseInsensitiveCompare(name) == .orderedSame }
        let canonical = aliases.contains(name) ? name : aliases.sorted().first ?? name
        for alias in aliases.union([canonical]) {
            environmentOverrides.removeValue(forKey: alias)
            environmentRemovals.insert(alias)
        }
        if let value {
            environmentOverrides[canonical] = value
            environmentRemovals.remove(canonical)
        }
    }

    private func expandEnvironment(_ value: String) -> String {
        var result = "", remainder = value[...]
        while let open = remainder.firstIndex(of: "%") {
            result += remainder[..<open]
            let start = remainder.index(after: open)
            guard let close = remainder[start...].firstIndex(of: "%") else {
                return result + remainder[open...]
            }
            let name = String(remainder[start..<close])
            let after = remainder.index(after: close)
            result += environmentValue(name) ?? String(remainder[open..<after])
            remainder = remainder[after...]
        }
        return result + remainder
    }

    @discardableResult
    private func skipEchoPrefix(in command: inout Substring) -> Bool {
        let trimmed = command.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == "@" else { return false }
        command = trimmed.drop(while: { $0 == "@" }).drop(while: { $0 == " " || $0 == "\t" })
        return true
    }

    private struct Condition {
        let negated: Bool
        let exists: Bool
        let operand: String
        let bareTilde: Bool
        let wildcard: Bool
        let expandPercent: Bool
        let remainder: Substring
    }

    private static func condition(in command: Substring) -> Condition? {
        var text = command.drop(while: { $0 == " " || $0 == "\t" })
        func consumeKeyword(_ word: String) -> Bool {
            let token = text.prefix(while: { $0 != " " && $0 != "\t" })
            guard token.lowercased() == word else { return false }
            text = text.dropFirst(token.count).drop(while: { $0 == " " || $0 == "\t" })
            return true
        }
        guard consumeKeyword("if") else { return nil }
        let negated = consumeKeyword("not")
        let exists = consumeKeyword("exist")
        guard exists || consumeKeyword("defined") else { return nil }

        var quote: Character?, escaped = false
        let end = text.firstIndex { character in
            if escaped { escaped = false; return false }
            if character == "\\", quote != "'" { escaped = true; return false }
            if let current = quote {
                if character == current { quote = nil }
                return false
            }
            if character == "\"" || character == "'" { quote = character; return false }
            return character == " " || character == "\t"
        }
        guard let end else { return nil }
        let operand = String(text[..<end])
        let remainder = text[end...].drop(while: { $0 == " " || $0 == "\t" })
        guard !remainder.isEmpty, let parsed = try? ShellCommand.lex(operand, allowIncomplete: false), parsed.tokens.count == 1,
              let token = parsed.tokens.first else { return nil }
        let wildcard = token.isBare && token.value.contains(where: { "*?[".contains($0) })
        let unsupportedOperand = parsed.unsupported && (!wildcard || token.value.contains(where: { "$`;|&<>\n\r(){}".contains($0) }))
        guard !unsupportedOperand else { return nil }
        return Condition(negated: negated, exists: exists, operand: token.value, bareTilde: token.leadingBareTilde,
                         wildcard: wildcard, expandPercent: operand.first != "'", remainder: remainder)
    }

    private static func matchesExistingFilename(_ path: URL) throws -> Bool {
        let directory = path.deletingLastPathComponent()
        let pattern = path.lastPathComponent
        guard let handle = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [],
            options: [.skipsSubdirectoryDescendants]) else { return false }
        // Bound synchronous checks initiated while building an association menu.
        for (index, value) in handle.enumerated() {
            guard index < ShellCommand.maximumCompletionEntries else {
                throw ShellCommandError.io("Проверка IF EXIST достигла предела просмотра папки.")
            }
            if let candidate = value as? URL, fnmatch(pattern, candidate.lastPathComponent, 0) == 0 { return true }
        }
        return false
    }

    private static func farCommand(_ command: String) -> InternalFarCommand? {
        guard command.hasPrefix("far:") else { return nil }
        let subcommand = command.dropFirst(4)
        switch subcommand.lowercased() {
        case "config": return .config
        case "about": return .about
        case "regex": return .regex
        case "log": return .log("")
        default: break
        }
        if subcommand.lowercased().hasPrefix("log ") {
            return .log(subcommand.dropFirst(4).trimmingCharacters(in: .whitespaces))
        }
        if subcommand.lowercased().hasPrefix("error") {
            let value = subcommand.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
            if value.hasPrefix("0x"), let code = UInt32(value.dropFirst(2), radix: 16) { return .error(code) }
            if let code = UInt32(value) { return .error(code) }
            if let code = Int32(value) { return .error(UInt32(bitPattern: code)) }
        }
        return nil
    }
}
