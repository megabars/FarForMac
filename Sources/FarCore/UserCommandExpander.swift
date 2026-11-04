import Foundation
import Darwin

public struct UserCommandInput: Equatable, Sendable {
    /// The complete placeholder body; repeated identical placeholders share one value.
    public let identifier: String
    public let title: String
    public let defaultValue: String
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
        "passiveName", "passivePath", "passiveStem", "passiveExtension", "passiveMarked", "passiveSelectedNames"
    ]
    static let listNames: Set<String> = ["list", "list0", "listNames", "listNames0", "passiveList", "passiveList0", "passiveListNames", "passiveListNames0"]
    private struct Token {
        let range: Range<String.Index>
        let name: String
        let input: UserCommandInput?
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
        var index = template.startIndex
        let boundaries = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|&;()< >"))
        func boundary(_ character: Character) -> Bool { character.unicodeScalars.allSatisfy { boundaries.contains($0) } }
        while index < template.endIndex {
            let character = template[index]
            let next = template.index(after: index)
            if character == "{" {
                guard let close = template[next...].firstIndex(of: "}") else { throw UserCommandError("Не закрыт параметр команды {…}.") }
                let name = String(template[next..<close])
                let input: UserCommandInput?
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
                } else {
                    guard names.contains(name) || listNames.contains(name) else { throw UserCommandError("Неизвестный параметр команды {\(name)}.") }
                    input = nil
                }
                let end = template.index(after: close)
                guard quote == nil, !escaped,
                      index == template.startIndex || boundary(template[template.index(before: index)]),
                      end == template.endIndex || boundary(template[end]) else {
                    throw UserCommandError("Параметр {\(name)} должен быть отдельным словом без кавычек и экранирования.")
                }
                result.append(Token(range: index..<end, name: name, input: input)); index = end; continue
            }
            if character == "#", quote == nil, !escaped,
               index == template.startIndex || boundary(template[template.index(before: index)]) {
                shellComment = true
            }
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
        return result
    }

    public static func expand(_ template: String, context: UserCommandContext, inputValues: [String: String] = [:]) throws -> String {
        try expand(template, context: context, inputValues: inputValues, lists: [:])
    }

    private static func expand(_ template: String, context: UserCommandContext, inputValues: [String: String], lists: [String: URL]) throws -> String {
        let substitutions = try tokens(template)
        var result = "", cursor = template.startIndex
        for token in substitutions {
            let values: [String]
            let name = token.name
            if let input = token.input {
                guard let value = inputValues[input.identifier] else { throw UserCommandError("Не введён параметр «\(input.title)».") }
                guard value.utf8.count <= 65_536, !value.contains("\0") else { throw UserCommandError("Введённый параметр превышает 64 КиБ или содержит NUL.") }
                values = [value]
            } else if listNames.contains(name) {
                guard let url = lists[name] else { throw UserCommandError("Параметр {\(name)} требует подготовки временного list-файла.") }
                values = [url.path]
            } else {
                let passive = name.hasPrefix("passive") && name != "passive"
                let file = passive ? context.passiveCurrentFile : context.currentFile
                let key = passive ? String(name.dropFirst(7)).lowercased() : name
                switch key {
                case "name", "path", "stem", "extension":
                    guard let file else { throw UserCommandError("Для {\(name)} выберите текущий файл на соответствующей панели.") }
                    switch key {
                    case "name": values = [file.lastPathComponent]
                    case "stem": values = [file.deletingPathExtension().lastPathComponent]
                    case "extension": values = [file.pathExtension]
                    default: values = [file.path]
                    }
                case "selectedNames", "selectednames":
                    let marked = passive ? context.passiveMarkedFiles : context.markedFiles
                    let selected = marked.isEmpty ? file.map { [$0] } ?? [] : marked
                    guard !selected.isEmpty else { throw UserCommandError("Для {\(name)} выберите текущий файл или пометьте файлы на соответствующей панели.") }
                    values = selected.map(\.lastPathComponent)
                case "marked":
                    let marked = passive ? context.passiveMarkedFiles : context.markedFiles
                    guard !marked.isEmpty else { throw UserCommandError("Для {\(name)} пометьте хотя бы один файл на соответствующей панели.") }
                    values = marked.map(\.path)
                case "active": values = [context.activeDirectory.path]
                default: values = [context.passiveDirectory.path]
                }
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

    /// Creates no resources unless a list placeholder is present. Newline lists
    /// reject newline-containing names; NUL lists preserve every valid POSIX name.
    public static func prepare(_ template: String, context: UserCommandContext, inputValues: [String: String] = [:]) throws -> PreparedUserCommand {
        let requested = Set(try tokens(template).map(\.name)).intersection(listNames)
        var directory: URL?, files: [String: URL] = [:]
        do {
            if !requested.isEmpty {
                var pattern = Array(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FarCommand-XXXXXX").path.utf8CString)
                guard mkdtemp(&pattern) != nil else { throw UserCommandError("Не удалось создать приватную папку list-файлов.") }
                directory = URL(fileURLWithPath: String(cString: pattern), isDirectory: true)
                var total = 0
                for name in requested.sorted() {
                    let passive = name.hasPrefix("passive")
                    let marked = passive ? context.passiveMarkedFiles : context.markedFiles
                    let current = passive ? context.passiveCurrentFile : context.currentFile
                    let selected = marked.isEmpty ? current.map { [$0] } ?? [] : marked
                    guard !selected.isEmpty, selected.count <= 100_000 else { throw UserCommandError("Для list-файла выберите текущий файл или пометьте до 100000 файлов.") }
                    let nul = name.hasSuffix("0"), namesOnly = name.contains("Names")
                    var data = Data()
                    for file in selected {
                        let value = namesOnly ? file.lastPathComponent : file.path
                        guard !value.contains("\0"), nul || (!value.contains("\n") && !value.contains("\r")) else {
                            throw UserCommandError("Имя содержит перевод строки: используйте list0 вместо текстового list-файла.")
                        }
                        total += value.utf8.count + 1
                        guard total <= 8_388_608 else { throw UserCommandError("List-файлы команды превышают 8 МиБ.") }
                        data.append(contentsOf: value.utf8); data.append(nul ? 0 : 10)
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
            return try PreparedUserCommand(command: expand(template, context: context, inputValues: inputValues, lists: files), listFiles: files, directory: directory, isEphemeral: !files.isEmpty || !inputs(in: template).isEmpty)
        } catch {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }
}
