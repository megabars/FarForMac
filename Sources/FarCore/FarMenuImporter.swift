import Foundation

public struct FarMenuImportResult: Sendable {
    public let menu: [UserMenuEntry]
    public let warnings: [String]
}

/// An explicit, conservative translation to this application's POSIX templates.
/// Parsing or importing never executes a command and never writes configuration.
public enum FarMenuImporter {
    public static func parse(_ data: Data) throws -> FarMenuImportResult {
        try parse(data, native: false)
    }

    public static func parseNative(_ data: Data) throws -> FarMenuImportResult {
        try parse(data, native: true)
    }

    static func decodeText(_ data: Data) throws -> String {
        guard data.count <= UserCommandConfiguration.maximumBytes else { throw UserCommandError("Меню превышает 256 КиБ.") }
        let text: String
        if data.starts(with: [0xff, 0xfe]), let decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            text = decoded
        } else if data.starts(with: [0xfe, 0xff]), let decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            text = decoded
        } else if let decoded = String(data: data, encoding: .utf8) {
            text = decoded.hasPrefix("\u{feff}") ? String(decoded.dropFirst()) : decoded
        } else { throw UserCommandError("Импорт поддерживает UTF-8 и UTF-16 с BOM; перекодируйте OEM/ANSI-файл перед импортом.") }
        guard !text.contains("\0") else { throw UserCommandError("Меню содержит NUL.") }
        return text
    }

    static func encodeText(_ text: String, original: Data?) throws -> Data {
        let encodings: [([UInt8], String.Encoding)] = [
            ([0xff, 0xfe], .utf16LittleEndian), ([0xfe, 0xff], .utf16BigEndian), ([0xef, 0xbb, 0xbf], .utf8)
        ]
        for (bom, encoding) in encodings where original?.starts(with: bom) == true {
            guard let encoded = text.data(using: encoding) else { throw UserCommandError("Не удалось сохранить кодировку меню.") }
            return Data(bom) + encoded
        }
        return Data(text.utf8)
    }

    static func lines(in block: String) -> [String] {
        block.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    public static func commandLines(in block: String) -> [String] {
        lines(in: block).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            let suffix = line.dropFirst(3)
            let isRemark = line.prefix(3).lowercased() == "rem" && (suffix.isEmpty || suffix.first?.isWhitespace == true)
            return line.isEmpty || line.hasPrefix("::") || isRemark ? nil : line
        }
    }

    static func validateCommandBlock(_ block: String) throws {
        guard block.utf8.count <= UserCommandConfiguration.maximumBytes, !block.contains("\0"),
              lines(in: block).allSatisfy({ $0.utf8.count <= 16_384 }) else {
            throw UserCommandError("Строка команды FarMenu.ini должна быть без NUL и не длиннее 16 КиБ.")
        }
    }

    static func serialize(_ menu: [UserMenuEntry], lineEnding: String) -> String {
        var result = ""
        func append(_ line: String) { result += line + lineEnding }
        func write(_ entries: [UserMenuEntry]) {
            for entry in entries {
                let key = entry.separator == true ? "--" : entry.key ?? ""
                append(key + ": " + entry.title)
                if let children = entry.children {
                    append("{")
                    write(children)
                    append("}")
                } else if let command = entry.command, !command.isEmpty {
                    for line in lines(in: command) { append("     " + line) }
                }
            }
        }
        write(menu)
        return result
    }

    private static func parse(_ data: Data, native: Bool) throws -> FarMenuImportResult {
        let text = try decodeText(data)
        let lines = lines(in: text)
        var index = 0, count = 0, warnings = Set<String>()
        func failure(_ message: String, line: Int) -> UserCommandError { UserCommandError("FarMenu.ini, строка \(line): \(message)") }
        func parseLevel(depth: Int, nested: Bool) throws -> [UserMenuEntry] {
            guard depth <= 8 else { throw failure("Допустимо не более 8 уровней меню.", line: index + 1) }
            var entries: [UserMenuEntry] = []
            var commands: [String] = []
            func finishCommands() {
                if !commands.isEmpty {
                    entries[entries.count - 1].command = commands.joined(separator: "\n")
                    commands.removeAll(keepingCapacity: true)
                }
            }
            while index < lines.count {
                let line = lines[index], number = index + 1
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                index += 1
                if trimmed.isEmpty || (trimmed.hasPrefix(";") && (!native || !trimmed.hasPrefix(";:") && line.first?.isWhitespace != true)) { continue }
                let structural = !native || line.first?.isWhitespace != true
                if native && structural { finishCommands() }
                if structural && trimmed == "}" {
                    guard nested else { throw failure("Лишняя закрывающая скобка.", line: number) }
                    return entries
                }
                if structural && trimmed == "{" {
                    guard let previous = entries.popLast(), previous.separator != true,
                          previous.command == nil || (native && previous.command == ""), previous.children == nil else {
                        throw failure("Подменю должно следовать за заголовком без команд.", line: number)
                    }
                    let children = try parseLevel(depth: depth + 1, nested: true)
                    entries.append(UserMenuEntry(title: previous.title, children: children, key: previous.key, farSyntax: native))
                    continue
                }
                if line.first?.isWhitespace == true {
                    if native {
                        guard let previous = entries.last, previous.separator != true, previous.children == nil else {
                            throw failure("Команда должна следовать за заголовком пункта.", line: number)
                        }
                        commands.append(trimmed)
                        continue
                    }
                    guard var previous = entries.popLast(), previous.separator != true, previous.children == nil else {
                        throw failure("Команда должна следовать за заголовком пункта.", line: number)
                    }
                    let converted: String
                    do { converted = try convertCommand(trimmed) }
                    catch { throw failure(error.localizedDescription, line: number) }
                    if let command = previous.command {
                        // FAR's sequential Windows lines are intentionally not silently
                        // reinterpreted: shell &&, ; and per-line cwd differ observably.
                        _ = command
                        throw failure("Несколько строк команды требуют ручного переноса в POSIX-скрипт.", line: number)
                    }
                    previous.command = converted; entries.append(previous)
                    continue
                }
                guard let colon = trimmed.hasPrefix("::") && native
                    ? trimmed.index(after: trimmed.startIndex) : trimmed.firstIndex(of: ":") else {
                    throw failure("Ожидается заголовок «клавиша: Название».", line: number)
                }
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let title = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                count += 1
                guard count <= 512 else { throw failure("В меню допустимо не более 512 пунктов.", line: number) }
                if key == "--" || (key == "-" && title.isEmpty) {
                    entries.append(UserMenuEntry(title: title.isEmpty && !native ? "—" : title, separator: true, farSyntax: native))
                } else {
                    guard !title.isEmpty else { throw failure("Пустое название пункта.", line: number) }
                    entries.append(UserMenuEntry(title: title, command: native ? "" : nil, key: key.isEmpty ? nil : key, farSyntax: native))
                }
            }
            guard !nested else { throw failure("Не закрыто подменю.", line: lines.count) }
            finishCommands()
            return entries
        }
        let menu = try parseLevel(depth: 1, nested: false)
        guard native || !menu.isEmpty else { throw UserCommandError("FarMenu.ini не содержит пунктов меню.") }
        try UserCommandConfiguration(menu: menu).validate()
        warnings.insert("Проверьте каждую команду для POSIX-shell: Windows-программы, cmd/batch и пути автоматически не переводятся.")
        if !native {
            warnings.insert("Подставляемые значения заключаются в POSIX-кавычки. Истории и переменные интерактивных параметров FAR не переносятся.")
        }
        return FarMenuImportResult(menu: menu, warnings: warnings.sorted())
    }

    public static func convertCommand(_ command: String) throws -> String {
        // Recognize complete argument forms first; arbitrary concatenations and
        // quoted fragments fail validation after translation instead of weakening quoting.
        let source = command
        var result = "", index = source.startIndex
        var passive = false
        func appendParameter(_ value: String) {
            // Whole quoted metasymbol arguments are safely replaced by the already
            // quoted native expansion. Composite quoted arguments remain invalid.
            if result.hasSuffix("\""), index < source.endIndex, source[index] == "\"" {
                result.removeLast(); result += value; index = source.index(after: index)
            } else { result += value }
        }
        while index < source.endIndex {
            guard source[index] == "!" else { result.append(source[index]); index = source.index(after: index); continue }
            let tail = source[index...]
            if tail.hasPrefix("!!") { result += "!"; index = source.index(index, offsetBy: 2); continue }
            if tail.hasPrefix("!#") || tail.hasPrefix("!^") {
                passive = tail.hasPrefix("!#"); index = source.index(index, offsetBy: 2); continue
            }
            if tail.hasPrefix("![") || tail.hasPrefix("!]") || tail.hasPrefix("!~") || tail.hasPrefix("!$") || tail.hasPrefix("!-!") || tail.hasPrefix("!+!") || tail.hasPrefix("!:") || tail.hasPrefix("!?!") || tail.hasPrefix("!=") || tail.hasPrefix("!/") {
                throw UserCommandError("Неподдерживаемый метасимвол FAR; замените его вручную на параметр POSIX-команды.")
            }
            if tail.hasPrefix("!?") {
                let start = source.index(index, offsetBy: 2)
                guard let middle = source[start...].firstIndex(of: "?"), let end = source[source.index(after: middle)...].firstIndex(of: "!") else {
                    throw UserCommandError("Неверный интерактивный параметр FAR.")
                }
                let title = String(source[start..<middle]), initial = String(source[source.index(after: middle)..<end])
                guard !title.hasPrefix("$"), !title.contains("("), !initial.contains("("), !title.contains("|"), !title.contains("{"), !initial.contains("{"), !title.contains("}"), !initial.contains("}") else {
                    throw UserCommandError("Истории и вложенные метасимволы интерактивного параметра перенесите вручную.")
                }
                index = source.index(after: end); appendParameter("{input:\(title)|\(initial)}"); continue
            }
            if tail.hasPrefix("!@") {
                let start = source.index(index, offsetBy: 2)
                guard let end = source[start...].firstIndex(of: "!") else { throw UserCommandError("Не закрыт list-параметр FAR.") }
                let modifiers = String(source[start..<end])
                guard modifiers.allSatisfy({ "UFS".contains($0) }) else { throw UserCommandError("List-файлы FAR: поддерживаются U/F/S; Q/A/W требуют ручного переноса.") }
                let token = modifiers.contains("F") ? "List" : "ListNames"
                index = source.index(after: end); appendParameter("{" + (passive ? "passive" + token : token.prefix(1).lowercased() + token.dropFirst()) + "}"); continue
            }
            let token: String, consumed: Int
            if tail.hasPrefix("!.!") { token = "Name"; consumed = 3 }
            else if tail.hasPrefix("!&") {
                token = "SelectedNames"; consumed = tail.hasPrefix("!&Q") ? 3 : 2
                if tail.hasPrefix("!&q") || tail.hasPrefix("!&~") { throw UserCommandError("Некавыченный/короткий список FAR не поддерживается.") }
            }
            else if tail.hasPrefix("!\\!.!") { token = "Path"; consumed = 5 }
            else if tail.hasPrefix("!\\") { token = passive ? "passive" : "active"; consumed = 2 }
            else if tail.hasPrefix("!`") { token = "Extension"; consumed = 2 }
            else { token = "Stem"; consumed = 1 }
            index = source.index(index, offsetBy: consumed)
            let native: String
            if token == "active" || token == "passive" { native = token }
            else { native = passive ? "passive" + token : token.prefix(1).lowercased() + token.dropFirst() }
            appendParameter("{" + native + "}")
        }
        // FAR variables and conditionals must not become misleading POSIX text.
        if result.range(of: #"%[A-Za-z_][A-Za-z0-9_{}]*%|%UserVar[0-9]+|%RegexGroup"#, options: .regularExpression) != nil || result.range(of: #"(?i)^@?(if\s|for\s|rem\s)"#, options: .regularExpression) != nil || result.hasPrefix("@") {
            throw UserCommandError("Условия, переменные и префиксы Windows/FAR требуют ручного переноса в POSIX-shell.")
        }
        try UserCommandExpander.validate(result)
        return result
    }
}
