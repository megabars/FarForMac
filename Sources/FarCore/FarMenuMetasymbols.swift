import Foundation

/// The FAR menu language is interpreted before forwarding one line to the POSIX dispatcher.
public enum FarMenuMetasymbols {
    public static func command(_ source: String, context: UserCommandContext,
                               variables: [String: String] = [:], variablesArePrivate: Bool = false) throws -> String {
        var aliases: [String: Int] = [:]
        let template = try substitute(source, context: context, rendering: .command, variables: variables, aliases: &aliases)
        let expanded = try replaceVariables(in: template, variables: variables, aliases: aliases, rendering: .command, variablesArePrivate: variablesArePrivate)
        try UserCommandExpander.validate(expanded)
        return expanded
    }

    public static func title(_ source: String, context: UserCommandContext,
                             variables: [String: String] = [:]) -> String {
        var unused: [String: Int] = [:]
        let text = (try? substitute(source, context: context, rendering: .title, variables: variables, aliases: &unused)) ?? source
        // FAR uses & for highlighting and && for a literal ampersand.
        var result = "", marked = false
        for character in text {
            if character == "&" {
                if marked { result.append(character) }
                marked.toggle()
            } else {
                marked = false
                result.append(character.isNewline ? " " : character)
            }
        }
        return String(result.prefix(512))
    }

    static func associationTemplate(_ source: String, captures: [String: String]) throws -> String {
        try replaceVariables(in: source, variables: captures, aliases: [:], rendering: .command)
    }

    static func referencedCaptures(in source: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)%RegexGroup(?:[0-9]+|\{[\p{L}\p{N}_ ]+\})"#) else { return [:] }
        var names: [String: String] = [:]
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            if let range = Range(match.range, in: source) { names[String(source[range].dropFirst())] = "" }
        }
        return names
    }

    private enum Rendering { case command, title, prompt }

    private static func substitute(_ source: String, context: UserCommandContext, rendering: Rendering,
                                   variables: [String: String], aliases: inout [String: Int],
                                   initiallyPassive: Bool = false) throws -> String {
        var result = ""
        var index = source.startIndex
        var passive = initiallyPassive
        var promptNumber = 0
        func switchPanel(_ tail: Substring) -> Bool? {
            if tail.hasPrefix("!#") { return true }
            if tail.hasPrefix("!^") { return false }
            if tail.hasPrefix("![") { return !context.activePanelIsLeft }
            if tail.hasPrefix("!]") { return context.activePanelIsLeft }
            return nil
        }
        func appendParameter(_ parameter: String) throws {
            if rendering != .command {
                let text = (try? UserCommandExpander.fileValues(for: parameter, context: context).joined(separator: " ")) ?? ""
                result += rendering == .title ? text.replacingOccurrences(of: "&", with: "&&") : text
                return
            }
            appendPlaceholder(parameter, to: &result, in: source, after: &index)
        }

        let unsupported = ["!&~", "!&q", "!`~", "!~", "!$", "!-!", "!+!", "!:", "!/", "!=/"]
        while index < source.endIndex {
            guard source[index] == "!" else {
                result.append(source[index])
                index = source.index(after: index)
                continue
            }
            let tail = source[index...]
            if tail.hasPrefix("!!") {
                result.append("!")
                index = source.index(index, offsetBy: 2)
            } else if let nextPanel = switchPanel(tail) {
                passive = nextPanel
                index = source.index(index, offsetBy: 2)
            } else if tail.hasPrefix("!?!") {
                index = source.index(index, offsetBy: 3)
                try appendParameter(passive ? "farDescriptionP" : "farDescriptionA")
            } else if let symbol = unsupported.first(where: { tail.hasPrefix($0) }) {
                guard rendering != .command else { throw UserCommandError("Метасимвол FAR \(symbol) недоступен для POSIX-shell.") }
                result += symbol
                index = source.index(index, offsetBy: symbol.count)
            } else if tail.hasPrefix("!?") {
                let start = source.index(index, offsetBy: 2)
                guard let middle = delimiter("?", from: start, in: source[...]),
                      let end = delimiter("!", from: source.index(after: middle), in: source[...]) else {
                    throw UserCommandError("Не закрыт интерактивный параметр FAR.")
                }
                let original = source[index...end]
                var label = source[start..<middle]
                let initial = source[source.index(after: middle)..<end]
                index = source.index(after: end)
                if rendering != .command { result += original; continue }
                promptNumber += 1
                guard promptNumber <= 16 else {
                    throw UserCommandError("В команде допустимо не более 16 интерактивных параметров.")
                }
                var history = "UserVar" + String(promptNumber - 1)
                var variable = ""
                if label.first == "$", let close = label.dropFirst().firstIndex(of: "$") {
                    history = String(label[label.index(after: label.startIndex)..<close])
                    variable = history
                    label = label[label.index(after: close)...]
                }
                guard history.utf8.count <= 256, !history.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw UserCommandError("Имя истории параметра FAR превышает 256 байт или содержит управляющие символы.")
                }
                let title = try promptText(label, context: context, variables: variables, passive: passive)
                let defaultValue = try promptText(initial, context: context, variables: variables, passive: passive)
                aliases["UserVar" + String(promptNumber)] = promptNumber
                if !variable.isEmpty, aliases.keys.allSatisfy({ $0.caseInsensitiveCompare(variable) != .orderedSame }) {
                    aliases[variable] = promptNumber
                }
                let fields = [String(promptNumber), displayControls(title), displayControls(defaultValue), history, variable]
                try appendParameter("farInput:" + UserCommandExpander.encodedFields(fields))
            } else if tail.hasPrefix("!@") {
                let start = source.index(index, offsetBy: 2)
                guard let end = source[start...].firstIndex(of: "!") else { throw UserCommandError("Не закрыт list-параметр FAR.") }
                let modifiers = Set(source[start..<end])
                guard modifiers.allSatisfy({ "FQSUW".contains($0) }), !modifiers.contains("U") || !modifiers.contains("W") else {
                    throw UserCommandError("List-файлы FAR поддерживают F/Q/S/U/W; ANSI-кодировка требует переноса.")
                }
                let original = source[index...end]
                index = source.index(after: end)
                if rendering != .command { result += original; continue }
                let flags = String(modifiers.filter { "FQW".contains($0) }.sorted())
                try appendParameter("farList" + (passive ? "P" : "A") + flags)
            } else if tail.hasPrefix("!\\") || tail.hasPrefix("!=\\") {
                let real = tail.hasPrefix("!=\\")
                index = source.index(index, offsetBy: real ? 3 : 2)
                let nextPanel = switchPanel(source[index...])
                let fileIsPassive = nextPanel ?? passive
                let fileIndex = nextPanel == nil ? index : source.index(index, offsetBy: 2)
                if source[fileIndex...].hasPrefix("!.!") {
                    let sides = (passive ? "P" : "A") + (fileIsPassive ? "P" : "A")
                    let ordinaryPath = passive == fileIsPassive ? (passive ? "passivePath" : "path") : "farPath" + sides
                    index = source.index(fileIndex, offsetBy: 3)
                    let path = real ? "farRealPath" + sides : ordinaryPath
                    passive = fileIsPassive
                    try appendParameter(path)
                } else {
                    try appendParameter((passive ? "passive" : "active") + (real ? "Real" : ""))
                }
            } else {
                let symbol: String, name: String
                if tail.hasPrefix("!.!") { symbol = "!.!"; name = "Name" }
                else if tail.hasPrefix("!&Q") { symbol = "!&Q"; name = "SelectedNames" }
                else if tail.hasPrefix("!&") { symbol = "!&"; name = "SelectedNames" }
                else if tail.hasPrefix("!`") { symbol = "!`"; name = "Extension" }
                else { symbol = "!"; name = "Stem" }
                index = source.index(index, offsetBy: symbol.count)
                try appendParameter(passive ? "passive" + name : name.prefix(1).lowercased() + name.dropFirst())
            }
            guard result.utf8.count <= 16_384 else { throw UserCommandError("Подстановки FAR превышают 16 КиБ.") }
        }
        if rendering != .command {
            return try replaceVariables(in: result, variables: variables, aliases: [:], rendering: rendering)
        }
        return result
    }

    private static func delimiter(_ delimiter: Character, from start: String.Index, in text: Substring) -> String.Index? {
        var depth = 0
        for index in text[start...].indices {
            let character = text[index]
            if character == delimiter, depth == 0 { return index }
            if character == "(" { depth += 1 }
            else if character == ")", depth > 0 { depth -= 1 }
        }
        return nil
    }

    private static func promptText(_ field: Substring, context: UserCommandContext,
                                   variables: [String: String], passive: Bool) throws -> String {
        var remainder = field, result = ""
        while let open = remainder.firstIndex(of: "(") {
            let start = remainder.index(after: open)
            guard let close = delimiter(")", from: start, in: remainder) else { break }
            var unused: [String: Int] = [:]
            let original = String(remainder[start..<close])
            let expanded = try substitute(original, context: context, rendering: .prompt,
                                          variables: variables, aliases: &unused, initiallyPassive: passive)
            result += remainder[..<open]
            result += expanded == original ? String(remainder[open...close]) : expanded
            remainder = remainder[remainder.index(after: close)...]
        }
        return result + remainder
    }

    private static func displayControls(_ value: String) -> String {
        String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
    }

    private static func appendPlaceholder(_ name: String, to result: inout String, in source: String,
                                          after index: inout String.Index) {
        // The downstream scanner accepts placeholders as entire shell words.
        if result.hasSuffix("\""), index < source.endIndex, source[index] == "\"" {
            result.removeLast()
            index = source.index(after: index)
        }
        func insideWord(_ character: Character) -> Bool {
            !character.isWhitespace && !"|&;()<>".contains(character)
        }
        let hasPrefix = result.last.map(insideWord) ?? false
        let hasSuffix = index < source.endIndex && insideWord(source[index])
        let key = hasPrefix || hasSuffix ? "farWord:" + name : name
        result += "{" + key + "}"
    }

    private static func replaceVariables(in source: String, variables: [String: String],
                                         aliases: [String: Int], rendering: Rendering, variablesArePrivate: Bool = false) throws -> String {
        let keys = Set(variables.keys).union(aliases.keys).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }
        var result = "", cursor = source.startIndex
        while let mark = source[cursor...].firstIndex(of: "%") {
            result += source[cursor..<mark]
            let start = source.index(after: mark)
            let tail = source[start...]
            if let key = keys.first(where: { key in
                guard let end = tail.index(tail.startIndex, offsetBy: key.count, limitedBy: tail.endIndex),
                      tail[..<end].caseInsensitiveCompare(key) == .orderedSame else { return false }
                return !key.lowercased().hasPrefix("regexgroup") && !key.lowercased().hasPrefix("uservar")
                    || end == tail.endIndex || !tail[end].isNumber
            }) {
                cursor = source.index(start, offsetBy: key.count)
                if let value = variables[key] {
                    if rendering == .command {
                        let parameter = (variablesArePrivate ? "farPrivate:" : "farValue:") + UserCommandExpander.encodedFields([value])
                        appendPlaceholder(parameter, to: &result, in: source, after: &cursor)
                    } else {
                        result += rendering == .title ? value.replacingOccurrences(of: "&", with: "&&") : value
                    }
                } else if let index = aliases[key], rendering == .command {
                    appendPlaceholder("farInputRef:" + String(index), to: &result, in: source, after: &cursor)
                }
            } else {
                result.append("%")
                cursor = start
            }
        }
        return result + source[cursor...]
    }
}
