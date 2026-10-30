import Foundation
import Darwin

public enum ShellCommandError: Error, LocalizedError, Equatable {
    case nullByte, tooLong, invalidSyntax, unsupportedSyntax, invalidDirectory, previousDirectoryUnavailable, io(String)
    public var errorDescription: String? {
        switch self {
        case .nullByte: return "Команда или путь содержит нулевой символ."
        case .tooLong: return "Команда превышает предел 64 КиБ."
        case .invalidSyntax: return "Незавершённая кавычка или экранирование в команде."
        case .unsupportedSyntax: return "Дополнение поддерживает только буквальные пути без shell-подстановок и составных команд."
        case .invalidDirectory: return "Рабочий каталог должен быть локальным абсолютным путём."
        case .previousDirectoryUnavailable: return "Предыдущий каталог для cd - пока не задан."
        case .io(let message): return message
        }
    }
}

public struct ShellPathCandidate: Equatable, Sendable {
    public let path: String
    public let isDirectory: Bool
    /// Entire command with its last token replaced by a quoted absolute path.
    public let commandLine: String
}

public struct ShellPathCompletion: Equatable, Sendable {
    public let candidates: [ShellPathCandidate]
    public let scannedEntryCount: Int
    /// The scan or result bound was reached; candidates are not exhaustive.
    public let isTruncated: Bool
}

/// Literal command-line helpers. These functions never invoke a shell, expand
/// variables, evaluate command substitutions, or read shell startup files.
public enum ShellCommand {
    public static let maximumCommandBytes = 65_536
    public static let maximumCompletionEntries = 1_000

    /// POSIX single-quote encoding, including embedded apostrophes and newlines.
    public static func quoteArgument(_ argument: String) throws -> String {
        guard !argument.utf8.contains(0) else { throw ShellCommandError.nullByte }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Only a simple, literal `cd [--] [path]` changes the panel directory.
    /// Bare ~ and ~/ use homeDirectory; bare - uses previousDirectory. Quoted
    /// '~' and '-' are literal names. Variables, globbing, ~user, redirects,
    /// pipelines, assignments and compound commands are delegated in full to
    /// the terminal (nil), without changing either panel's directory.
    /// The caller must successfully load the returned directory before commit.
    public static func directoryChange(in command: String, currentDirectory: URL,
                                       previousDirectory: URL? = nil,
                                       homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL? {
        try validate(command)
        let parsed = try lex(command, allowIncomplete: false)
        guard !parsed.unsupported, let first = parsed.tokens.first, first.value == "cd" else { return nil }
        var arguments = Array(parsed.tokens.dropFirst())
        var afterOptions = false
        if arguments.first?.value == "--" { arguments.removeFirst(); afterOptions = true }
        guard arguments.count <= 1 else { return nil }
        try validateDirectory(currentDirectory)
        guard let token = arguments.first else { try validateDirectory(homeDirectory); return homeDirectory.standardizedFileURL }
        // An explicitly empty argument is not the no-argument home shortcut.
        guard !token.value.isEmpty else { return nil }
        if token.value == "-", token.isBare, !afterOptions {
            guard let previousDirectory else { throw ShellCommandError.previousDirectoryUnavailable }
            try validateDirectory(previousDirectory)
            return previousDirectory.standardizedFileURL
        }
        if token.value.hasPrefix("-"), token.isBare, !afterOptions { return nil }
        if token.value.hasPrefix("~"), token.leadingBareTilde,
           token.value != "~", !token.value.hasPrefix("~/") { return nil }
        return try resolve(token.value, bareTilde: token.leadingBareTilde,
                           currentDirectory: currentDirectory, homeDirectory: homeDirectory)
    }

    /// Completes the final token (an unfinished quote is permitted). Only the
    /// first 1,000 directory entries are examined, without loading the entire
    /// directory into memory. Invoke off the UI thread for slow filesystems.
    public static func completePath(in command: String, currentDirectory: URL,
                                    maximumResults: Int = 100,
                                    maximumScannedEntries: Int = maximumCompletionEntries,
                                    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> ShellPathCompletion {
        try validate(command)
        try validateDirectory(currentDirectory)
        let parsed = try lex(command, allowIncomplete: true)
        guard !parsed.unsupported else { throw ShellCommandError.unsupportedSyntax }
        let trailingSpace = parsed.endsInWhitespace
        let token = trailingSpace ? nil : parsed.tokens.last
        let value = token?.value ?? ""
        if value.hasPrefix("~"), token?.leadingBareTilde == true, value != "~", !value.hasPrefix("~/") {
            throw ShellCommandError.unsupportedSyntax
        }
        let isDirectoryPrefix = value.isEmpty || value.hasSuffix("/") || (value == "~" && token?.leadingBareTilde == true)
        // Split before normalising: a final '.' is a hidden-name prefix, not
        // a request to replace the current directory's own basename.
        let directoryText = isDirectoryPrefix ? value : (value as NSString).deletingLastPathComponent
        let directory = try resolve(directoryText, bareTilde: token?.leadingBareTilde == true,
                                    currentDirectory: currentDirectory, homeDirectory: homeDirectory)
        let prefix = isDirectoryPrefix ? "" : (value as NSString).lastPathComponent
        let insertion = token?.start ?? command.endIndex
        let initialCommand = String(command[..<insertion])
        let scanLimit = max(1, min(maximumScannedEntries, maximumCompletionEntries))
        let resultLimit = max(1, min(maximumResults, maximumCompletionEntries))
        guard let handle = opendir(directory.path) else { throw ShellCommandError.io(String(cString: strerror(errno))) }
        defer { closedir(handle) }
        var candidates: [ShellPathCandidate] = []
        var scanned = 0, truncated = false
        while true {
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { throw ShellCommandError.io(String(cString: strerror(errno))) }
                break
            }
            let name: String = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard scanned < scanLimit else { truncated = true; break }
            scanned += 1
            guard name.hasPrefix(prefix), prefix.hasPrefix(".") || !name.hasPrefix(".") else { continue }
            guard candidates.count < resultLimit else { truncated = true; continue }
            let candidate = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            let insertionPath = candidate.path + (isDirectory.boolValue ? "/" : "")
            candidates.append(ShellPathCandidate(path: candidate.path, isDirectory: isDirectory.boolValue,
                                                 commandLine: initialCommand + (try quoteArgument(insertionPath))))
        }
        candidates.sort { $0.path < $1.path }
        return ShellPathCompletion(candidates: candidates, scannedEntryCount: scanned, isTruncated: truncated)
    }

    private static func validate(_ command: String) throws {
        guard command.utf8.count <= maximumCommandBytes else { throw ShellCommandError.tooLong }
        guard !command.utf8.contains(0) else { throw ShellCommandError.nullByte }
    }
    private static func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0) else {
            throw ShellCommandError.invalidDirectory
        }
    }
    private static func resolve(_ value: String, bareTilde: Bool, currentDirectory: URL, homeDirectory: URL) throws -> URL {
        if bareTilde, value == "~" || value.hasPrefix("~/") {
            try validateDirectory(homeDirectory)
            return value == "~" ? homeDirectory.standardizedFileURL : homeDirectory.appendingPathComponent(String(value.dropFirst(2))).standardizedFileURL
        }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL }
        return currentDirectory.appendingPathComponent(value).standardizedFileURL
    }

    private struct Token {
        var value: String
        var start: String.Index
        var isBare: Bool
        var leadingBareTilde: Bool
    }
    private struct Lexed {
        var tokens: [Token]
        var unsupported: Bool
        var endsInWhitespace: Bool
    }
    private enum Quote { case single, double }

    private static func lex(_ command: String, allowIncomplete: Bool) throws -> Lexed {
        var tokens: [Token] = [], token: Token?, quote: Quote?, escaped = false
        var unsupported = false, endsInWhitespace = false
        for index in command.indices {
            let character = command[index]
            if token == nil, character == " " || character == "\t" { endsInWhitespace = true; continue }
            if token == nil { token = Token(value: "", start: index, isBare: true, leadingBareTilde: character == "~") }
            endsInWhitespace = false
            if escaped {
                // In double quotes backslash is only special before these.
                if quote == .double, !["$", "`", "\"", "\\", "\n"].contains(character) { token!.value.append("\\") }
                if character != "\n" { token!.value.append(character) }
                escaped = false
                continue
            }
            if quote == .single {
                if character == "'" { quote = nil } else { token!.value.append(character) }
                continue
            }
            if character == "\\" { token!.isBare = false; escaped = true; continue }
            if quote == .double {
                if character == "\"" { quote = nil }
                else { if character == "$" || character == "`" { unsupported = true }; token!.value.append(character) }
                continue
            }
            if character == "'" || character == "\"" {
                if token!.value.isEmpty { token!.leadingBareTilde = false }
                token!.isBare = false
                quote = character == "'" ? .single : .double
            } else if character == " " || character == "\t" {
                tokens.append(token!); token = nil; endsInWhitespace = true
            } else {
                if "$`;|&<>\n\r(){}*?[]".contains(character) || (character == "#" && token!.value.isEmpty) { unsupported = true }
                token!.value.append(character)
            }
        }
        // Once shell syntax is present, this lexer no longer owns parsing.
        // Quotes inside comments / here-documents need not balance as ordinary
        // words do; the terminal shell must receive the original text intact.
        if !unsupported {
            if !allowIncomplete, quote != nil || escaped { throw ShellCommandError.invalidSyntax }
            if escaped { throw ShellCommandError.invalidSyntax }
        }
        if let token { tokens.append(token) }
        return Lexed(tokens: tokens, unsupported: unsupported, endsInWhitespace: endsInWhitespace)
    }
}
