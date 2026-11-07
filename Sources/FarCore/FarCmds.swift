import Foundation

public enum FarCmdsPrefix: String, CaseIterable, Sendable {
    case view, edit, goto, clip, whereis, link, run, load, unload
}

public enum FarCmdsStream: Int, Codable, CaseIterable, Sendable {
    case combined, stdout, stderr, separate
}

public enum FarCmdsDisplay: Int, Codable, CaseIterable, Sendable {
    case hide, keep, echo
}

public struct FarCmdsOptions: Codable, Equatable, Sendable {
    public var display: FarCmdsDisplay
    public var stream: FarCmdsStream
    public var openEmptyOutput: Bool
    public var editNewFiles: Bool
    public var maximumReadBytes: Int
    public static let defaultReadBytes = 1024 * 1024
    public static let maximumReadLimit = 16 * 1024 * 1024

    public init(display: FarCmdsDisplay = .hide, stream: FarCmdsStream = .combined,
                openEmptyOutput: Bool = true, editNewFiles: Bool = true,
                maximumReadBytes: Int = FarCmdsOptions.defaultReadBytes) {
        self.display = display
        self.stream = stream
        self.openEmptyOutput = openEmptyOutput
        self.editNewFiles = editNewFiles
        self.maximumReadBytes = maximumReadBytes
    }

    public var readLimit: Int {
        maximumReadBytes <= 0 ? Self.defaultReadBytes : min(maximumReadBytes, Self.maximumReadLimit)
    }
}

public struct FarCmdsError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct FarCmdsCommand: Equatable, Sendable {
    public struct Position: Equatable, Sendable {
        public let line: Int
        public let column: Int
    }

    public struct Capture: Equatable, Sendable {
        public let command: String
        public let directory: String?
        public let stream: FarCmdsStream
        public let display: FarCmdsDisplay
        public let destination: String?
    }

    public struct Link: Equatable, Sendable {
        public let source: String
        public let destination: String
        public let symbolic: Bool
        public let refresh: Bool
        public let showErrors: Bool
    }

    public enum Operand: Equatable, Sendable {
        case path(String)
        case pathInFile(String)
        case capture(Capture)
        case link(Link)
    }

    public let prefix: FarCmdsPrefix
    public let operand: Operand
    public let position: Position?

    public init(prefix: FarCmdsPrefix, arguments: String, options: FarCmdsOptions = .init(),
                environment: [String: String] = [:]) throws {
        guard arguments.utf8.count <= 65_536, !arguments.utf8.contains(0) else {
            throw FarCmdsError("Строка FAR Commands превышает допустимый размер.")
        }
        self.prefix = prefix
        var text = arguments
        var position: Position?
        if prefix == .edit, text.first == "[", let bracket = text.firstIndex(of: "]"),
           !text[..<bracket].contains(where: \.isWhitespace) {
            let components = text[text.index(after: text.startIndex)..<bracket].split(separator: ",", omittingEmptySubsequences: false)
            guard (1...2).contains(components.count) else { throw Self.syntax(prefix) }
            func coordinate(_ index: Int) throws -> Int {
                guard components.indices.contains(index), !components[index].isEmpty else { return 1 }
                let source = Self.expand(String(components[index]), environment: environment)
                guard let value = Int(source), value > 0, value <= Int32.max else { throw Self.syntax(prefix) }
                return value
            }
            position = try Position(line: coordinate(0), column: coordinate(1))
            text = String(text[text.index(after: bracket)...])
        }
        self.position = position
        text = Self.trim(text)
        guard !text.isEmpty else { throw Self.syntax(prefix) }

        if prefix == .link {
            operand = .link(try Self.parseLink(text, environment: environment))
            return
        }

        if prefix == .run {
            guard let marker = Self.unquotedMarker(in: text) else { throw Self.syntax(prefix) }
            let destination = try Self.path(String(text[..<marker]), environment: environment, prefix: prefix)
            operand = .capture(try Self.capture(String(text[text.index(after: marker)...]), destination: destination,
                                                prefix: prefix, options: options, environment: environment))
            return
        }

        let fromFile = text.first == "<"
        if [.goto, .whereis, .load, .unload].contains(prefix) {
            let source = fromFile ? String(text.dropFirst()) : text
            let path = try Self.path(source, environment: environment, prefix: prefix)
            operand = fromFile ? .pathInFile(path) : .path(path)
        } else if fromFile {
            operand = .capture(try Self.capture(String(text.dropFirst()), destination: nil, prefix: prefix,
                                                options: options, environment: environment))
        } else {
            operand = .path(try Self.path(text, environment: environment, prefix: prefix))
        }
    }

    public static func expand(_ string: String, environment: [String: String]) -> String {
        let folded = environment.reduce(into: [String: String]()) { $0[$1.key.uppercased()] = $1.value }
        var source = string[...], result = ""
        while let start = source.firstIndex(of: "%") {
            result += source[..<start]
            let rest = source[source.index(after: start)...]
            guard let end = rest.firstIndex(of: "%") else { return result + source[start...] }
            let name = String(rest[..<end])
            if !name.isEmpty, let value = environment[name] ?? folded[name.uppercased()] { result += value }
            else { result += source[start...end] }
            source = rest[rest.index(after: end)...]
        }
        return result + source
    }

    private static func capture(_ input: String, destination: String?, prefix: FarCmdsPrefix,
                                options: FarCmdsOptions, environment: [String: String]) throws -> Capture {
        var input = input[...]
        var stream = options.stream, display = options.display
        if let first = input.first {
            switch first {
            case "1": stream = .stdout; input.removeFirst()
            case "2": stream = .stderr; input.removeFirst()
            case "*": stream = .combined; input.removeFirst()
            case "?": stream = .separate; input.removeFirst()
            default: break
            }
        }
        if let first = input.first {
            switch first {
            case ">": display = .hide; input.removeFirst()
            case "<": display = .keep; input.removeFirst()
            case "+": display = .echo; input.removeFirst()
            default: break
            }
        }
        if stream == .separate, prefix == .run { stream = .combined }
        if stream == .separate, display == .echo { display = .keep }
        var command = trim(String(input))
        var directory: String?
        if command.first == "|" {
            let suffix = command.dropFirst()
            guard let marker = suffix.firstIndex(of: "|") else { throw syntax(prefix) }
            directory = try path(String(suffix[..<marker]), environment: environment, prefix: prefix)
            command = trim(String(suffix[suffix.index(after: marker)...]))
        }
        command = expand(command, environment: environment)
        guard !command.isEmpty, command.utf8.count <= 65_536, !command.utf8.contains(0) else { throw syntax(prefix) }
        return Capture(command: command, directory: directory, stream: stream, display: display, destination: destination)
    }

    private static func parseLink(_ input: String, environment: [String: String]) throws -> Link {
        var text = input
        var symbolic = false, refresh = true, showErrors = false
        while let token = text.split(maxSplits: 1, whereSeparator: \.isWhitespace).first {
            switch token.lowercased() {
            case "/s": symbolic = true
            case "/n": refresh = false
            case "/msg": showErrors = true
            default:
                let (source, destination) = try splitFirstPath(text)
                return try Link(source: path(source, environment: environment, prefix: .link),
                                destination: path(destination, environment: environment, prefix: .link),
                                symbolic: symbolic, refresh: refresh, showErrors: showErrors)
            }
            text = trim(String(text.dropFirst(token.count)))
        }
        throw syntax(.link)
    }

    private static func splitFirstPath(_ text: String) throws -> (String, String) {
        if text.first == "\"",
           let end = text.dropFirst().firstIndex(of: "\"") {
            let after = text.index(after: end)
            guard after < text.endIndex, text[after].isWhitespace else { throw syntax(.link) }
            return (String(text[...end]), String(text[after...]))
        }
        guard let space = text.firstIndex(where: \.isWhitespace) else { throw syntax(.link) }
        return (String(text[..<space]), String(text[space...]))
    }

    private static func unquotedMarker(in input: String) -> String.Index? {
        var quoted = false
        for index in input.indices {
            if input[index] == "\"" { quoted.toggle() }
            if !quoted, input[index] == "<" { return index }
        }
        return nil
    }

    private static func path(_ raw: String, environment: [String: String], prefix: FarCmdsPrefix) throws -> String {
        var text = trim(raw)
        if text.first == "\"" || text.last == "\"" {
            guard text.first == "\"", text.last == "\"", text.count >= 2 else { throw syntax(prefix) }
            text = String(text.dropFirst().dropLast())
        }
        text = expand(text, environment: environment)
        guard !text.isEmpty, text.utf8.count <= 65_536, !text.utf8.contains(0) else { throw syntax(prefix) }
        return text
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func syntax(_ prefix: FarCmdsPrefix) -> FarCmdsError {
        FarCmdsError("Синтаксис FAR Commands: \(prefix.rawValue):[параметры] объект")
    }
}
