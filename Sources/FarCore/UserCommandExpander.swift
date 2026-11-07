import Foundation
import Darwin

public struct UserCommandInput: Equatable, Sendable {
    /// The complete placeholder body; repeated identical placeholders share one value.
    public let identifier: String
    public let title: String
    public let defaultValue: String
    /// Nil disables history. Only explicitly named histories create FAR variables.
    public let historyName: String?
    public let variableName: String?
    let farIndex: Int?

    init(identifier: String, title: String, defaultValue: String,
         historyName: String? = nil, variableName: String? = nil, farIndex: Int? = nil) {
        self.identifier = identifier
        self.title = title
        self.defaultValue = defaultValue
        self.historyName = historyName
        self.variableName = variableName
        self.farIndex = farIndex
    }
}

/// Temporary list files belong to one reviewed command. Keep this object alive until
/// the foreground command finishes, or while its text remains in the command bar.
public final class PreparedUserCommand {
    public let command: String
    public let listFiles: [String: URL]
    public let isEphemeral: Bool
    private var directory: URL?
    init(command: String, listFiles: [String: URL], directory: URL?, isEphemeral: Bool) {
        self.command = command; self.listFiles = listFiles; self.directory = directory; self.isEphemeral = isEphemeral
    }
    public func cleanup() {
        guard let directory else { return }
        self.directory = nil
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { cleanup() }
}

public enum UserCommandExpander {
    private static let names: Set<String> = [
        "name", "path", "stem", "extension", "marked", "selectedNames", "active", "passive",
        "passiveName", "passivePath", "passiveStem", "passiveExtension", "passiveMarked", "passiveSelectedNames",
        "activeReal", "passiveReal", "farDescriptionA", "farDescriptionP", "farPathAP", "farPathPA", "farRealPathAA", "farRealPathAP", "farRealPathPA", "farRealPathPP"
    ]
    private struct ListOptions {
        let passive: Bool
        let namesOnly: Bool
        let nul: Bool
        let quotes: Bool
        let utf16: Bool

        init?(_ name: String) {
            let passive = name.hasPrefix("passive")
            let body = passive ? String(name.dropFirst("passive".count)) : name
            if ["list", "list0", "listNames", "listNames0", "List", "List0", "ListNames", "ListNames0"].contains(body) {
                guard body.first?.isUppercase == passive else { return nil }
                self.init(passive: passive, namesOnly: body.contains("Names"), nul: body.hasSuffix("0"))
            } else if name.hasPrefix("farListA") || name.hasPrefix("farListP") {
                let modifiers = String(name.dropFirst("farListA".count))
                guard modifiers.allSatisfy({ "FQW".contains($0) }), modifiers == String(Set(modifiers).sorted()) else { return nil }
                self.init(passive: name.hasPrefix("farListP"), namesOnly: !modifiers.contains("F"),
                          nul: false, quotes: modifiers.contains("Q"), utf16: modifiers.contains("W"))
            } else { return nil }
        }

        private init(passive: Bool, namesOnly: Bool, nul: Bool, quotes: Bool = false, utf16: Bool = false) {
            self.passive = passive; self.namesOnly = namesOnly; self.nul = nul
            self.quotes = quotes; self.utf16 = utf16
        }
    }
    private struct Token {
        let range: Range<String.Index>
        let name: String
        let input: UserCommandInput?
        let reference: Int?
        let literal: String?
    }
    public static func validate(_ template: String) throws { _ = try tokens(template) }
    public static func inputs(in template: String) throws -> [UserCommandInput] {
        var seen = Set<String>()
        let result = try tokens(template).compactMap(\.input).filter { seen.insert($0.identifier).inserted }
        guard result.count <= 16 else { throw UserCommandError("В команде допустимо не более 16 интерактивных параметров.") }
        return result
    }
    private static func tokens(_ template: String) throws -> [Token] {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              template.utf8.count <= 16_384, !template.contains("\0") else {
            throw UserCommandError("Команда должна быть непустой, без NUL и не длиннее 16 КиБ.")
        }
        var result: [Token] = []
        var quote: Character?, escaped = false, shellComment = false
        var previousIsBoundary = true
        var index = template.startIndex
        let boundaries = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|&;()< >"))
        func boundary(_ character: Character) -> Bool { character.unicodeScalars.allSatisfy { boundaries.contains($0) } }
        while index < template.endIndex {
            let character = template[index]
            let next = template.index(after: index)
            if character == "{" {
                guard let close = template[next...].firstIndex(of: "}") else { throw UserCommandError("Не закрыт параметр команды {…}.") }
                let marker = String(template[next..<close])
                let composite = marker.hasPrefix("farWord:")
                let name = composite ? String(marker.dropFirst("farWord:".count)) : marker
                var input: UserCommandInput?
                var reference: Int?
                var literal: String?
                if name.hasPrefix("input:") {
                    let components = name.dropFirst(6).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    let title = String(components[0])
                    let initial = components.count > 1 ? String(components[1]) : ""
                    guard !title.trimmingCharacters(in: .whitespaces).isEmpty, title.utf8.count <= 256,
                          initial.utf8.count <= 4096, !name.contains("{"),
                          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        throw UserCommandError("Интерактивный параметр: {input:Название|начальный текст}, без управляющих символов.")
                    }
                    input = UserCommandInput(identifier: name, title: title, defaultValue: initial)
                } else if name.hasPrefix("farInput:"),
                          let parts = decodedFields(name.dropFirst("farInput:".count)), parts.count == 5,
                          let index = Int(parts[0]), (1...16).contains(index),
                          parts[1].utf8.count <= 256, parts[2].utf8.count <= 4096, parts[3].utf8.count <= 256 {
                    input = UserCommandInput(identifier: name, title: parts[1], defaultValue: parts[2],
                        historyName: parts[3].isEmpty ? nil : parts[3],
                        variableName: parts[4].isEmpty ? nil : parts[4], farIndex: index)
                } else if name.hasPrefix("farInputRef:"), let index = Int(name.dropFirst("farInputRef:".count)), (1...16).contains(index) {
                    reference = index
                } else if name.hasPrefix("farValue:") || name.hasPrefix("farPrivate:"),
                          let colon = name.firstIndex(of: ":"),
                          let parts = decodedFields(name[name.index(after: colon)...]), parts.count == 1 {
                    literal = parts[0]
                } else {
                    guard names.contains(name) || ListOptions(name) != nil else { throw UserCommandError("Неизвестный параметр команды {\(name)}.") }
                }
                let end = template.index(after: close)
                let completeWord = previousIsBoundary && (end == template.endIndex || boundary(template[end]))
                func validAffix(_ value: String) -> Bool {
                    value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-./+,=:".contains($0)) }
                }
                let singleValue = !name.lowercased().contains("selectednames") && !name.lowercased().contains("marked")
                let safeComposite = composite && singleValue &&
                    validAffix(String(template[..<index].reversed().prefix { !boundary($0) })) &&
                    validAffix(String(template[end...].prefix { !boundary($0) }))
                guard quote == nil, !escaped, completeWord || safeComposite else {
                    throw UserCommandError("Параметр {\(name)} требует отдельного слова или буквального суффикса FAR.")
                }
                result.append(Token(range: index..<end, name: name, input: input, reference: reference, literal: literal))
                previousIsBoundary = false
                index = end
                continue
            }
            if character == "#", quote == nil, !escaped,
               index == template.startIndex || boundary(template[template.index(before: index)]) {
                shellComment = true
            }
            previousIsBoundary = quote == nil && !escaped && boundary(character)
            if escaped { escaped = false }
            else if character == "\\", quote != "'" { escaped = true }
            else if let current = quote { if character == current { quote = nil } }
            else if character == "'" || character == "\"" { quote = character }
            index = next
        }
        if !result.isEmpty, shellComment {
            throw UserCommandError("Параметры нельзя использовать в шаблоне с shell-комментарием #; удалите комментарий или используйте отдельный скрипт.")
        }
        if !result.isEmpty, template.contains("$(") || template.contains("$'") || template.contains("$\"") || template.contains("`") || template.contains("<<") || template.contains("\n") || template.contains("\r") {
            throw UserCommandError("Параметры поддерживаются в однострочных командах без подстановки команд и here-document; используйте отдельный скрипт.")
        }
        guard Set(result.compactMap { $0.input?.identifier }).count <= 16 else {
            throw UserCommandError("В команде допустимо не более 16 интерактивных параметров.")
        }
        let farIndices = Set(result.compactMap { $0.input?.farIndex })
        guard result.allSatisfy({ token in token.reference.map(farIndices.contains) ?? true }) else {
            throw UserCommandError("Команда ссылается на отсутствующий параметр FAR.")
        }
        return result
    }

    static func encodedFields(_ fields: [String]) -> String {
        Data(fields.joined(separator: "\0").utf8).base64EncodedString()
    }

    private static func decodedFields(_ value: Substring) -> [String]? {
        guard let data = Data(base64Encoded: String(value)), let string = String(data: data, encoding: .utf8) else { return nil }
        return string.components(separatedBy: "\0")
    }

    static func preview(_ template: String, context: UserCommandContext) throws -> String {
        try expand(template, context: context, inputValues: [:], lists: [:], preview: true)
    }

    public static func expand(_ template: String, context: UserCommandContext, inputValues: [String: String] = [:]) throws -> String {
        try expand(template, context: context, inputValues: inputValues, lists: [:])
    }

    private static func expand(_ template: String, context: UserCommandContext, inputValues: [String: String], lists: [String: URL],
                               preview: Bool = false) throws -> String {
        let substitutions = try tokens(template)
        var byIndex: [Int: UserCommandInput] = [:]
        for input in substitutions.compactMap(\.input) {
            if let index = input.farIndex { byIndex[index] = input }
        }
        var result = "", cursor = template.startIndex
        for token in substitutions {
            let values: [String]
            let name = token.name
            if let input = token.input ?? token.reference.flatMap({ byIndex[$0] }) {
                guard let value = preview ? token.name : inputValues[input.identifier] else { throw UserCommandError("Не введён параметр «\(input.title)».") }
                guard value.utf8.count <= 65_536, !value.contains("\0") else { throw UserCommandError("Введённый параметр превышает 64 КиБ или содержит NUL.") }
                values = [value]
            } else if let literal = token.literal {
                values = [literal]
            } else if ListOptions(name) != nil {
                guard let path = preview ? name : lists[name]?.path else { throw UserCommandError("Параметр {\(name)} требует подготовки временного list-файла.") }
                values = [path]
            } else {
                values = try fileValues(for: name, context: context)
            }
            result += template[cursor..<token.range.lowerBound]
            result += try values.map(ShellCommand.quoteArgument).joined(separator: " ")
            guard result.utf8.count <= 1_048_576 else { throw UserCommandError("Развёрнутая команда превышает 1 МиБ.") }
            cursor = token.range.upperBound
        }
        result += template[cursor...]
        guard result.utf8.count <= 1_048_576 else { throw UserCommandError("Развёрнутая команда превышает 1 МиБ.") }
        return result
    }

    static func fileValues(for name: String, context: UserCommandContext) throws -> [String] {
        if name == "farDescriptionA" || name == "farDescriptionP" {
            let passive = name == "farDescriptionP"
            guard let file = passive ? context.passiveCurrentFile : context.currentFile, file.isFileURL else { return [""] }
            let encoding = passive ? context.passiveDescriptionEncoding : context.activeDescriptionEncoding
            let descriptions = try FileDescriptions.load(directory: file.deletingLastPathComponent(), encoding: encoding)
            return [descriptions.description(for: file.lastPathComponent)]
        }
        if name == "activeReal" { return [context.activeDirectory.resolvingSymlinksInPath().path] }
        if name == "passiveReal" { return [context.passiveDirectory.resolvingSymlinksInPath().path] }
        if name.hasPrefix("farPath") || name.hasPrefix("farRealPath") {
            let side = name.suffix(2)
            let directory = side.first == "P" ? context.passiveDirectory : context.activeDirectory
            let file = side.last == "P" ? context.passiveCurrentFile : context.currentFile
            guard let file else { throw UserCommandError("Выберите текущий файл на соответствующей панели.") }
            let base = name.hasPrefix("farRealPath") ? directory.resolvingSymlinksInPath() : directory
            return [base.appendingPathComponent(file.lastPathComponent).path]
        }
        let passive = name.hasPrefix("passive") && name != "passive"
        let file = passive ? context.passiveCurrentFile : context.currentFile
        let key = passive ? String(name.dropFirst(7)).lowercased() : name
        switch key {
        case "name", "path", "stem", "extension":
            guard let file else { throw UserCommandError("Для {\(name)} выберите текущий файл на соответствующей панели.") }
            switch key {
            case "name": return [file.lastPathComponent]
            case "stem": return [file.deletingPathExtension().lastPathComponent]
            case "extension": return [file.pathExtension]
            default: return [file.path]
            }
        case "selectedNames", "selectednames":
            let marked = passive ? context.passiveMarkedFiles : context.markedFiles
            let selected = marked.isEmpty ? file.map { [$0] } ?? [] : marked
            guard !selected.isEmpty else { throw UserCommandError("Для {\(name)} выберите текущий файл или пометьте файлы на соответствующей панели.") }
            return selected.map(\.lastPathComponent)
        case "marked":
            let marked = passive ? context.passiveMarkedFiles : context.markedFiles
            guard !marked.isEmpty else { throw UserCommandError("Для {\(name)} пометьте хотя бы один файл на соответствующей панели.") }
            return marked.map(\.path)
        case "active": return [context.activeDirectory.path]
        case "passive": return [context.passiveDirectory.path]
        default: throw UserCommandError("Неизвестный параметр команды {\(name)}.")
        }
    }

    /// Creates no resources unless a list placeholder is present. Newline lists
    /// reject newline-containing names; NUL lists preserve every valid POSIX name.
    public static func prepare(_ template: String, context: UserCommandContext, inputValues: [String: String] = [:]) throws -> PreparedUserCommand {
        let substitutions = try tokens(template)
        let requested = Set(substitutions.map(\.name)).sorted().compactMap { name in
            ListOptions(name).map { (name, $0) }
        }
        var directory: URL?, files: [String: URL] = [:]
        do {
            if !requested.isEmpty {
                var pattern = Array(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FarCommand-XXXXXX").path.utf8CString)
                guard mkdtemp(&pattern) != nil else { throw UserCommandError("Не удалось создать приватную папку list-файлов.") }
                directory = URL(fileURLWithPath: String(cString: pattern), isDirectory: true)
                var total = 0
                for (name, options) in requested {
                    let marked = options.passive ? context.passiveMarkedFiles : context.markedFiles
                    let current = options.passive ? context.passiveCurrentFile : context.currentFile
                    let selected = marked.isEmpty ? current.map { [$0] } ?? [] : marked
                    guard !selected.isEmpty, selected.count <= 100_000 else { throw UserCommandError("Для list-файла выберите текущий файл или пометьте до 100000 файлов.") }
                    var data = options.utf16 ? Data([0xff, 0xfe]) : Data()
                    total += data.count
                    for file in selected {
                        let value = options.namesOnly ? file.lastPathComponent : file.path
                        guard !value.contains("\0"), options.nul || (!value.contains("\n") && !value.contains("\r")) else {
                            throw UserCommandError("Имя содержит перевод строки: используйте list0 вместо текстового list-файла.")
                        }
                        let escaped = options.quotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
                        let line = escaped + (options.nul ? "\0" : "\n")
                        let encoding: String.Encoding = options.utf16 ? .utf16LittleEndian : .utf8
                        guard let bytes = line.data(using: encoding) else {
                            throw UserCommandError("Не удалось записать имя в выбранной кодировке списка.")
                        }
                        total += bytes.count
                        guard total <= 8_388_608 else { throw UserCommandError("List-файлы команды превышают 8 МиБ.") }
                        data.append(bytes)
                    }
                    let url = directory!.appendingPathComponent(name)
                    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { throw UserCommandError("Не удалось создать приватный list-файл.") }
                    do {
                        defer { Darwin.close(fd) }
                        try data.withUnsafeBytes { bytes in
                            var offset = 0
                            while offset < bytes.count {
                                let amount = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                                if amount < 0, errno == EINTR { continue }
                                guard amount > 0 else { throw UserCommandError("Не удалось записать list-файл.") }
                                offset += amount
                            }
                        }
                    }
                    files[name] = url
                }
            }
            return try PreparedUserCommand(command: expand(template, context: context, inputValues: inputValues, lists: files), listFiles: files, directory: directory, isEphemeral: !files.isEmpty || substitutions.contains { $0.input != nil || $0.name.hasPrefix("farPrivate:") })
        } catch {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }
}
