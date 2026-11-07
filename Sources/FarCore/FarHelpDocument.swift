import Foundation

public enum FarHelpError: LocalizedError, Equatable {
    case invalidDocument, tooLarge, invalidCommand, missingTopic(String), cyclicAlias(String), unsupportedTarget(String)
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "Файл не содержит заголовок и темы HLF."
        case .tooLarge: return "Размер или структура HLF превышают допустимый предел."
        case .invalidCommand: return "Ожидается имя файла HLF или GUID и необязательное имя темы."
        case .missingTopic(let name): return "Тема HLF «\(name)» не найдена."
        case .cyclicAlias(let name): return "Циклический псевдоним темы HLF «\(name)»."
        case .unsupportedTarget(let target): return "Цель HLF «\(target)» недоступна."
        }
    }
}

public enum FarHelpTarget: Sendable, Equatable {
    case topic(String), file(String, topic: String?), host(String), unsupported(String)

    init(_ value: String) {
        if value.hasPrefix("<"), let end = value.firstIndex(of: ">") {
            let name = String(value[value.index(after: value.startIndex)..<end]).replacingOccurrences(of: "\\", with: "/")
            let topic = String(value[value.index(after: end)...])
            if !name.isEmpty, !name.contains(":"), name.lowercased().hasSuffix(".hlf") {
                self = .file(name, topic: topic.isEmpty ? nil : topic)
            } else { self = .unsupported(value) }
        } else if value.hasPrefix(":") {
            self = .host(String(value.dropFirst()))
        } else if !value.isEmpty, !value.contains(":") {
            self = .topic(value)
        } else {
            self = .unsupported(value)
        }
    }
}

public enum FarHelpInvocation: Sendable, Equatable {
    case usage, hostTopic(String), plugin(UUID, topic: String?), file(String, topic: String?), nameOrTopic(String)

    public init(arguments: String) throws {
        let text = arguments.trimmingCharacters(in: .whitespaces)
        guard text.utf8.count <= 65_536, !text.unicodeScalars.contains(where: {
            $0.value < 32 && $0.value != 9 || (127...159).contains($0.value)
        }) else { throw FarHelpError.invalidCommand }
        guard !text.isEmpty else { self = .usage; return }
        if text.hasPrefix("@") {
            let topic = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !topic.isEmpty else { throw FarHelpError.invalidCommand }
            self = .hostTopic(topic)
            return
        }
        let name: String, tail: String
        let quoted = text.first == "\""
        if quoted {
            let remainder = text.dropFirst()
            guard let quote = remainder.firstIndex(of: "\"") else { throw FarHelpError.invalidCommand }
            name = String(remainder[..<quote])
            tail = String(remainder[remainder.index(after: quote)...])
            guard tail.isEmpty || tail.first?.isWhitespace == true else { throw FarHelpError.invalidCommand }
        } else if let space = text.firstIndex(where: \.isWhitespace) {
            name = String(text[..<space])
            tail = String(text[space...])
        } else { name = text; tail = "" }
        guard !name.isEmpty else { throw FarHelpError.invalidCommand }
        var topic = tail.trimmingCharacters(in: .whitespaces)
        if topic.first == "@" { topic = String(topic.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let selected = topic.isEmpty ? nil : topic
        let guid = name.hasPrefix("{") && name.hasSuffix("}") ? String(name.dropFirst().dropLast()) : name
        if let identifier = UUID(uuidString: guid) { self = .plugin(identifier, topic: selected) }
        else if quoted || selected != nil || name.contains("/") || name.contains("\\") || name.lowercased().hasSuffix(".hlf") {
            self = .file(name, topic: selected)
        } else { self = .nameOrTopic(name) }
    }
}

public struct FarHelpRun: Sendable, Equatable {
    public let text: String
    public let highlighted: Bool
    public let link: FarHelpTarget?
    /// Low nibble is the foreground and high nibble is the background.
    public let consoleColor: UInt8?
}

public struct FarHelpParagraph: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case heading(centered: Bool), body, preformatted, rule(Character) }
    public let kind: Kind
    public let runs: [FarHelpRun]
    public let hangingIndent: Int?
    public var plainText: String { runs.map(\.text).joined() }
}

public struct FarHelpTopic: Sendable, Equatable {
    public let name: String
    /// Zero-based line of the topic declaration.
    public let sourceLine: Int
    public let paragraphs: [FarHelpParagraph]
}

public struct FarHelpDocument: Sendable {
    public let language: String
    public let title: String?
    public let topics: [FarHelpTopic]
    private let topicIndices: [String: Int]
    private let aliases: [String: String]

    private struct Options {
        var color: Character?
        var wrap: String?
        var tab = 8
    }

    public init(_ source: String) throws {
        guard source.utf8.count <= 8 * 1_024 * 1_024 else { throw FarHelpError.tooLarge }
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count <= 100_000 else { throw FarHelpError.tooLarge }
        guard let languageLine = lines.prefix(3).map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")) })
            .first(where: { $0.lowercased().hasPrefix(".language=") }) else { throw FarHelpError.invalidDocument }
        language = String(languageLine.dropFirst(10))
        var options = Options(), title: String?
        var topics: [FarHelpTopic] = [], indices: [String: Int] = [:], aliases: [String: String] = [:]
        var name: String?, line = 0, raw: [(FarHelpParagraph.Kind, String)] = []
        var formatting = true, atHeadings = true
        func appendTopic() throws {
            guard let name else { return }
            guard topics.count < 4096 else { throw FarHelpError.tooLarge }
            let key = Self.key(name)
            guard indices[key] == nil else { return }
            let paragraphs = raw.map { Self.paragraph($0.0, text: $0.1, options: options) }
            indices[key] = topics.count
            topics.append(FarHelpTopic(name: name, sourceLine: line, paragraphs: paragraphs))
        }
        for (index, original) in lines.enumerated() {
            guard original.utf16.count <= 65_536 else { throw FarHelpError.tooLarge }
            let row = Self.clean(original, tabSize: options.tab)
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if name == nil, trimmed.hasPrefix(".") {
                let fields = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if fields.count == 2 {
                    let value = String(fields[1])
                    switch fields[0].lowercased() {
                    case ".plugincontents": title = value
                    case ".options ctrlcolorchar": options.color = value.first
                    case ".options ctrlstartposchar": options.wrap = value.isEmpty ? nil : value
                    case ".options tabsize": if let size = Int(value), (0...16).contains(size) { options.tab = max(1, size) }
                    default: break
                    }
                }
                continue
            }
            if row.hasPrefix("@"), !row.hasPrefix("@@") {
                if name != nil, trimmed == "@+" || trimmed == "@-" {
                    formatting = trimmed == "@+"; atHeadings = false; continue
                }
                if name != nil, trimmed.hasPrefix("@=") {
                    raw.append((.rule(trimmed.dropFirst(2).first ?? "─"), "")); atHeadings = false; continue
                }
                let declaration = trimmed.dropFirst().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if declaration.count == 2, !declaration[0].isEmpty, !declaration[1].isEmpty {
                    aliases[Self.key(String(declaration[0]))] = String(declaration[1])
                    if name != nil { try appendTopic(); name = nil; raw.removeAll() }
                } else if !trimmed.dropFirst().isEmpty {
                    try appendTopic()
                    name = String(trimmed.dropFirst()); line = index
                    raw.removeAll(keepingCapacity: true); formatting = true; atHeadings = true
                }
                continue
            }
            guard name != nil else { continue }
            if atHeadings, row.hasPrefix("$") {
                let centered = row.hasPrefix("$^")
                raw.append((.heading(centered: centered), String(row.dropFirst(centered ? 2 : 1))))
                continue
            }
            atHeadings = false
            if !formatting { raw.append((.preformatted, row)); continue }
            if !trimmed.isEmpty, row.first?.isWhitespace != true, raw.last?.0 == .body, raw.last?.1.isEmpty == false {
                raw[raw.count - 1].1 += " " + row
            } else { raw.append((.body, trimmed.isEmpty ? "" : row)) }
        }
        try appendTopic()
        guard !topics.isEmpty else { throw FarHelpError.invalidDocument }
        self.title = title
        self.topics = topics
        topicIndices = indices
        self.aliases = aliases
    }

    public func topic(named name: String? = nil) throws -> FarHelpTopic {
        let wanted = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Contents"
        var key = Self.key(wanted), seen = Set<String>()
        while let alias = aliases[key] {
            guard seen.insert(key).inserted else { throw FarHelpError.cyclicAlias(wanted) }
            key = Self.key(alias)
        }
        guard let index = topicIndices[key] else { throw FarHelpError.missingTopic(wanted) }
        return topics[index]
    }

    public func topic(atSourceLine line: Int) -> FarHelpTopic {
        topics.last(where: { $0.sourceLine <= line }) ?? topics[0]
    }

    private static func key(_ name: String) -> String { name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }

    private static func clean(_ raw: Substring, tabSize: Int) -> String {
        var result = "", column = 0
        for scalar in raw.unicodeScalars {
            if scalar.value == 9 {
                let spaces = tabSize - column % tabSize
                result += String(repeating: " ", count: spaces); column += spaces
            } else if scalar.value >= 32, !(127...159).contains(scalar.value) {
                result.unicodeScalars.append(scalar); column += 1
            }
        }
        return result
    }

    private static func paragraph(_ kind: FarHelpParagraph.Kind, text: String, options: Options) -> FarHelpParagraph {
        var text = text
        var indent: Int?
        if let marker = options.wrap, let range = text.range(of: marker) {
            indent = inline(String(text[..<range.lowerBound]), colorMarker: options.color).reduce(0) { $0 + $1.text.count }
            text.removeSubrange(range)
        }
        return FarHelpParagraph(kind: kind, runs: inline(text, colorMarker: options.color), hangingIndent: indent)
    }

    private static func inline(_ text: String, colorMarker: Character?, link: FarHelpTarget? = nil) -> [FarHelpRun] {
        let characters = Array(text)
        var runs: [FarHelpRun] = [], pending = "", highlighted = false
        var color: UInt8?
        var index = 0
        func flush() {
            guard !pending.isEmpty else { return }
            runs.append(FarHelpRun(text: pending, highlighted: highlighted, link: link, consoleColor: color))
            pending = ""
        }
        func closing(_ delimiter: Character, from start: Int) -> Int? {
            var offset = start
            while offset < characters.count {
                if characters[offset] == delimiter {
                    if offset + 1 >= characters.count || characters[offset + 1] != delimiter { return offset }
                    offset += 1
                }
                offset += 1
            }
            return nil
        }
        while index < characters.count {
            let value = characters[index]
            if index + 1 < characters.count, characters[index + 1] == value,
               value == "#" || value == "@" || value == "~" || value == colorMarker {
                pending.append(value); index += 2; continue
            }
            if value == "#" { flush(); highlighted.toggle(); index += 1; continue }
            if value == colorMarker, index + 1 < characters.count {
                if characters[index + 1] == "-" { flush(); color = nil; index += 2; continue }
                if index + 2 < characters.count, let code = UInt8(String(characters[index + 1...index + 2]), radix: 16) {
                    flush(); color = code; index += 3; continue
                }
            }
            if value == "~", link == nil, let labelEnd = closing("~", from: index + 1),
               labelEnd + 1 < characters.count, characters[labelEnd + 1] == "@",
               let destinationEnd = closing("@", from: labelEnd + 2) {
                let target = String(characters[labelEnd + 2..<destinationEnd]).replacingOccurrences(of: "@@", with: "@")
                if !target.isEmpty {
                    flush()
                    let label = String(characters[index + 1..<labelEnd])
                    runs += inline(label, colorMarker: colorMarker, link: FarHelpTarget(target))
                    index = destinationEnd + 1; continue
                }
            }
            if value == "@", let end = closing("@", from: index + 1) {
                index = end + 1
                continue
            }
            pending.append(value)
            index += 1
        }
        flush()
        return runs
    }
}
