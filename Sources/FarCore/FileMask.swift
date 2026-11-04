import Foundation

/// FAR glob lists, quoted masks, named groups and explicit `/expression/imsx` regexes.
/// Globs match the complete filename, case-insensitively; regexes search within it.
/// Regex syntax is Foundation/ICU, rather than the complete FAR regex dialect.
/// Runtime deadlines are cooperative: ICU's progress callbacks cannot promise hard real-time cancellation.
public struct FileMask: Sendable {
    private let includes: [Matcher]
    private let excludes: [Matcher]
    private static let maximumPatternLength = 4_096
    private static let maximumExpandedLength = 65_536
    private static let maximumMasks = 1_024
    private static let maximumGroupReferences = 1_024
    private static let maximumGroupDepth = 16
    private static let maximumNameLength = 65_536

    public init(_ pattern: String, groups: [String: String] = [:]) throws {
        var references = 0
        let expanded = try Self.expand(pattern, groups: groups, stack: [], references: &references)
        let sections = try Self.sections(expanded)
        includes = try sections.include.map(Self.matcher)
        excludes = try sections.exclude.map(Self.matcher)
    }

    /// Compatibility API: a timeout or evaluation limit is reported as a non-match.
    public func matches(_ name: String) -> Bool {
        (try? matchesChecked(name)) ?? false
    }

    public func matchesChecked(_ name: String, timeLimit: TimeInterval = 0.01) throws -> Bool {
        try matches(name, deadline: Deadline(timeLimit))
    }

    /// One aggregate deadline covers all filenames. Callers can apply the returned set atomically.
    public func matchingNames(_ names: [String], timeLimit: TimeInterval = 0.25) throws -> Set<String> {
        let deadline = try Deadline(timeLimit)
        var result = Set<String>()
        for name in names {
            if try matches(name, deadline: deadline) { result.insert(name) }
        }
        try deadline.check()
        return result
    }

    private func matches(_ name: String, deadline: Deadline) throws -> Bool {
        try deadline.check()
        guard name.utf16.count <= Self.maximumNameLength else {
            throw MaskError("Имя файла превышает допустимую длину для проверки маски.")
        }
        let normalized = name.precomposedStringWithCanonicalMapping
        // Fold only when a glob is actually evaluated; regex case sensitivity is explicit.
        var characters: [String]?
        func matchesAny(_ matchers: [Matcher]) throws -> Bool {
            for matcher in matchers {
                try deadline.check()
                switch matcher {
                case .glob(let tokens):
                    if characters == nil { characters = normalized.map { Self.fold($0) } }
                    if try Self.matches(tokens, characters!, deadline: deadline) { return true }
                case .regex(let regex):
                    var matched = false
                    var timedOut = false
                    var internalError = false
                    regex.enumerateMatches(in: normalized, options: [.reportProgress, .reportCompletion],
                                           range: NSRange(normalized.startIndex..., in: normalized)) { result, flags, stop in
                        if deadline.expired {
                            timedOut = true
                            stop.pointee = true
                        } else if flags.contains(.internalError) {
                            internalError = true
                            stop.pointee = true
                        } else if result != nil {
                            matched = true
                            stop.pointee = true
                        }
                    }
                    if timedOut { throw MaskError("Превышено время проверки маски файлов.") }
                    if internalError { throw MaskError("Не удалось выполнить регулярное выражение маски.") }
                    try deadline.check()
                    if matched { return true }
                }
            }
            return false
        }
        let included = try matchesAny(includes)
        let excluded = included ? try matchesAny(excludes) : false
        try deadline.check()
        return included && !excluded
    }

    private enum Matcher: Sendable {
        case glob([Token])
        // NSRegularExpression is immutable and supports concurrent matching.
        case regex(NSRegularExpression)
    }

    private struct Deadline {
        let end: TimeInterval
        init(_ limit: TimeInterval) throws {
            guard limit.isFinite, limit > 0 else { throw MaskError("Время проверки маски должно быть положительным конечным числом.") }
            end = ProcessInfo.processInfo.systemUptime + limit
        }
        var expired: Bool { ProcessInfo.processInfo.systemUptime >= end }
        func check() throws {
            if expired { throw MaskError("Превышено время проверки маски файлов.") }
        }
    }

    private enum Token: Sendable {
        case star
        case any
        case literal(String)
        case characterClass(members: Set<String>, ranges: [ClosedRange<UInt32>], negated: Bool)

        func accepts(_ character: String) -> Bool {
            switch self {
            case .star, .any: return true
            case .literal(let value): return character == value
            case let .characterClass(members, ranges, negated):
                let scalar = character.unicodeScalars.count == 1 ? character.unicodeScalars.first?.value : nil
                let contains = members.contains(character) || scalar.map { value in ranges.contains { $0.contains(value) } } == true
                return negated ? !contains : contains
            }
        }
    }

    /// Shared linear scanner keeps delimiters inside quotes, classes and regexes opaque.
    private struct SyntaxState {
        var quoted = false
        var inClass = false
        var regex = false
        var escaped = false
        var atStart = true

        var isPlain: Bool { !quoted && !inClass && !regex }

        mutating func consume(_ character: Character) {
            if regex {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "/" { regex = false }
            } else if quoted {
                if character == "\"" { quoted = false }
            } else if inClass {
                if character == "]" { inClass = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "[" {
                inClass = true
            } else if character == "/", atStart {
                regex = true
            }
            if isPlain, character == "," || character == ";" || character == "|" {
                atStart = true
            } else if !character.isWhitespace {
                atStart = false
            }
        }
    }

    private static func expand(_ expression: String, groups: [String: String], stack: [String], references: inout Int) throws -> String {
        guard expression.utf16.count <= maximumPatternLength else {
            throw MaskError("Маска или определение группы длиннее 4096 символов.")
        }
        let characters = Array(expression)
        var state = SyntaxState()
        var result = ""
        var length = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if state.isPlain, character == "<" {
                var end = index + 1
                while end < characters.count, characters[end] != ">", characters[end] != "<" { end += 1 }
                guard end < characters.count, characters[end] == ">", end > index + 1 else {
                    throw MaskError("Неверная ссылка на группу масок: ожидается <имя>.")
                }
                let name = String(characters[(index + 1)..<end])
                guard let value = groups[name] else { throw MaskError("Неизвестная группа масок «\(name)».") }
                guard !stack.contains(name) else { throw MaskError("Циклическая ссылка на группу масок «\(name)».") }
                references += 1
                guard stack.count < maximumGroupDepth, references <= maximumGroupReferences else {
                    throw MaskError("Превышен предел вложенности или количества ссылок на группы масок.")
                }
                let expanded = try expand(value, groups: groups, stack: stack + [name], references: &references)
                length += expanded.utf16.count
                guard length <= maximumExpandedLength else { throw MaskError("Развёрнутая маска слишком длинная.") }
                result.append(expanded)
                // Expansion is textual, including its inclusion/exclusion separators.
                for expandedCharacter in expanded { state.consume(expandedCharacter) }
                index = end + 1
                continue
            }
            if state.isPlain, character == ">" { throw MaskError("Закрывающая скобка группы масок не имеет открывающей.") }
            length += character.utf16.count
            guard length <= maximumExpandedLength else { throw MaskError("Развёрнутая маска слишком длинная.") }
            result.append(character)
            state.consume(character)
            index += 1
        }
        return result
    }

    private static func sections(_ expression: String) throws -> (include: [String], exclude: [String]) {
        guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MaskError("Укажите непустую маску файлов.")
        }
        var state = SyntaxState()
        var current = ""
        var includes = [String]()
        var excludes = [String]()
        var excluding = false
        var afterListSeparator = false
        func appendCurrent() throws {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MaskError("Список содержит пустую маску файлов.") }
            guard includes.count + excludes.count < maximumMasks else { throw MaskError("Список содержит слишком много масок файлов.") }
            if excluding { excludes.append(trimmed) } else { includes.append(trimmed) }
            current = ""
        }
        for character in expression {
            if state.isPlain, character == "," || character == ";" || character == "|" {
                if character == "|" {
                    guard !excluding else { throw MaskError("В маске допустим только один разделитель «|».") }
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try appendCurrent() }
                    else if afterListSeparator { throw MaskError("Список содержит пустую маску файлов.") }
                    else { includes.append("*") }
                    excluding = true
                    afterListSeparator = false
                } else {
                    try appendCurrent()
                    afterListSeparator = true
                }
            } else {
                current.append(character)
                if !character.isWhitespace { afterListSeparator = false }
            }
            state.consume(character)
        }
        guard !state.quoted else { throw MaskError("Не закрыты двойные кавычки в маске файлов.") }
        guard !state.regex else { throw MaskError("Не закрыто регулярное выражение маски символом «/».") }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try appendCurrent() }
        else if afterListSeparator { throw MaskError("Список содержит пустую маску файлов.") }
        return (includes, excludes)
    }

    private static func matcher(_ raw: String) throws -> Matcher {
        var pattern = raw
        if pattern.first == "\"" {
            guard pattern.count >= 2, pattern.last == "\"" else { throw MaskError("Кавычки должны окружать отдельную маску целиком.") }
            pattern.removeFirst()
            pattern.removeLast()
            guard !pattern.isEmpty, !pattern.contains("\"") else { throw MaskError("Пустая маска или лишние кавычки в маске файлов.") }
            return .glob(try compile(pattern == "*.*" ? "*" : pattern))
        }
        if pattern.first == "/" {
            let characters = Array(pattern)
            var escaped = false
            var closing: Int?
            for index in 1..<characters.count {
                if escaped { escaped = false }
                else if characters[index] == "\\" { escaped = true }
                else if characters[index] == "/" { closing = index; break }
            }
            guard let closing else { throw MaskError("Не закрыто регулярное выражение маски символом «/».") }
            let body = String(characters[1..<closing])
            guard body.utf16.count <= maximumPatternLength else { throw MaskError("Регулярное выражение длиннее 4096 символов.") }
            var options: NSRegularExpression.Options = []
            for option in characters[(closing + 1)...] {
                switch option {
                case "i": options.insert(.caseInsensitive)
                case "m": options.insert(.anchorsMatchLines)
                case "s": options.insert(.dotMatchesLineSeparators)
                case "x": options.insert(.allowCommentsAndWhitespace)
                default: throw MaskError("Неизвестная опция регулярного выражения «\(option)»; допустимы i, m, s, x.")
                }
            }
            do { return .regex(try NSRegularExpression(pattern: body, options: options)) }
            catch { throw MaskError("Некорректное регулярное выражение в маске файлов.") }
        }
        guard !pattern.contains("\""), !pattern.contains("/") else { throw MaskError("Кавычки должны окружать маску целиком; пути в масках не поддерживаются.") }
        return .glob(try compile(pattern == "*.*" ? "*" : pattern))
    }
    private static func compile(_ pattern: String) throws -> [Token] {
        let characters = Array(pattern.precomposedStringWithCanonicalMapping)
        var tokens = [Token]()
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if case .star? = tokens.last {} else { tokens.append(.star) }
            case "?":
                tokens.append(.any)
            case "[":
                index += 1
                var negated = false
                if index < characters.count, characters[index] == "!" {
                    negated = true
                    index += 1
                }
                var contents = [Character]()
                while index < characters.count, characters[index] != "]" {
                    contents.append(characters[index])
                    index += 1
                }
                guard index < characters.count, !contents.isEmpty else {
                    throw MaskError("Незакрытый или пустой набор символов в квадратных скобках.")
                }
                tokens.append(try characterClass(contents, negated: negated))
            case "]":
                throw MaskError("Закрывающая квадратная скобка не имеет открывающей.")
            default:
                tokens.append(.literal(fold(character)))
            }
            index += 1
        }
        return tokens
    }

    private static func characterClass(_ characters: [Character], negated: Bool) throws -> Token {
        var members = Set<String>()
        var ranges = [ClosedRange<UInt32>]()
        var index = 0
        while index < characters.count {
            if index + 2 < characters.count, characters[index + 1] == "-" {
                let lower = fold(characters[index])
                let upper = fold(characters[index + 2])
                guard lower.unicodeScalars.count == 1, upper.unicodeScalars.count == 1,
                      let first = lower.unicodeScalars.first?.value,
                      let last = upper.unicodeScalars.first?.value, first <= last else {
                    throw MaskError("Недопустимый диапазон символов в маске.")
                }
                ranges.append(first...last)
                index += 3
            } else {
                members.insert(fold(characters[index]))
                index += 1
            }
        }
        return .characterClass(members: members, ranges: ranges, negated: negated)
    }

    private static func fold(_ character: Character) -> String {
        String(character).folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    // Iterative dynamic programming avoids glob backtracking. Check the shared deadline
    // inside the loops, so long globs cannot monopolise a bulk selection operation.
    private static func matches(_ tokens: [Token], _ characters: [String], deadline: Deadline) throws -> Bool {
        var previous = [Bool](repeating: false, count: characters.count + 1)
        previous[0] = true
        for (tokenIndex, token) in tokens.enumerated() {
            try deadline.check()
            // FAR CmpName's legacy mode accepts a final .* after an otherwise
            // complete match, or a final . when the source has no dot at all.
            // Keep the bounded DP matcher; these are terminal alternatives only.
            if !characters.isEmpty, previous[characters.count], case .literal(".") = token {
                if tokenIndex == tokens.count - 1, !characters.contains(".") { return true }
                if tokenIndex == tokens.count - 2, case .star = tokens[tokenIndex + 1] { return true }
            }
            var current = [Bool](repeating: false, count: characters.count + 1)
            if case .star = token {
                current[0] = previous[0]
                for index in characters.indices {
                    if index & 255 == 0 { try deadline.check() }
                    current[index + 1] = previous[index + 1] || current[index]
                }
            } else {
                for index in characters.indices {
                    if index & 255 == 0 { try deadline.check() }
                    current[index + 1] = previous[index] && token.accepts(characters[index])
                }
            }
            previous = current
        }
        try deadline.check()
        return previous[characters.count]
    }

    private struct MaskError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
