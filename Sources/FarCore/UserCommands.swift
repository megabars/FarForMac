import Foundation
import Darwin

public struct UserCommandError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public enum UserCommandAction: String, Codable, Sendable { case execute, view, edit }

public struct UserMenuEntry: Codable, Equatable, Sendable {
    public var title: String
    public var command: String?
    public var children: [UserMenuEntry]?
    public var key: String?
    public init(title: String, command: String? = nil, children: [UserMenuEntry]? = nil, key: String? = nil) {
        self.title = title; self.command = command; self.children = children; self.key = key
    }
}

public struct UserFileAssociation: Codable, Equatable, Sendable {
    public var title: String
    public var mask: String
    public var execute: String?
    public var view: String?
    public var edit: String?
    public init(title: String, mask: String, execute: String? = nil, view: String? = nil, edit: String? = nil) {
        self.title = title; self.mask = mask; self.execute = execute; self.view = view; self.edit = edit
    }
    public func command(for action: UserCommandAction) -> String? {
        switch action { case .execute: return execute; case .view: return view; case .edit: return edit }
    }
}

public struct UserCommandConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var menu: [UserMenuEntry]
    public var associations: [UserFileAssociation]
    public init(version: Int = 1, menu: [UserMenuEntry] = [], associations: [UserFileAssociation] = []) {
        self.version = version; self.menu = menu; self.associations = associations
    }
    private enum CodingKeys: String, CodingKey { case version, menu, associations }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        menu = try values.decodeIfPresent([UserMenuEntry].self, forKey: .menu) ?? []
        associations = try values.decodeIfPresent([UserFileAssociation].self, forKey: .associations) ?? []
    }
    public static let maximumBytes = 262_144

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw UserCommandError("Конфигурация команд превышает 256 КиБ.") }
        // Bound structural nesting before either JSON parser constructs recursive objects.
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 24 else { throw UserCommandError("Слишком глубокая вложенность JSON.") }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            try checkKeys(object)
            let config = try JSONDecoder().decode(Self.self, from: data)
            try config.validate()
            return config
        } catch let error as UserCommandError { throw error }
        catch { throw UserCommandError("Неверная конфигурация команд JSON: \(error.localizedDescription)") }
    }

    private static func checkKeys(_ value: Any) throws {
        func keys(_ value: Any, allowed: Set<String>) throws -> [String: Any] {
            guard let object = value as? [String: Any] else { throw UserCommandError("Ожидается объект JSON.") }
            if let key = object.keys.sorted().first(where: { !allowed.contains($0) }) {
                throw UserCommandError("Неизвестное поле конфигурации: \(key).")
            }
            return object
        }
        func menu(_ value: Any) throws {
            guard let entries = value as? [Any] else { throw UserCommandError("Поле menu/children должно быть массивом.") }
            for entry in entries {
                let object = try keys(entry, allowed: ["title", "command", "children", "key"])
                if let children = object["children"] { try menu(children) }
            }
        }
        let root = try keys(value, allowed: ["version", "menu", "associations"])
        if let entries = root["menu"] { try menu(entries) }
        if let entries = root["associations"] as? [Any] {
            for entry in entries { _ = try keys(entry, allowed: ["title", "mask", "execute", "view", "edit"]) }
        }
    }

    public func validate() throws {
        guard version == 1 else { throw UserCommandError("Поддерживается только версия конфигурации 1.") }
        var count = 0
        func title(_ value: String) throws {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 512,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw UserCommandError("Название команды должно содержать 1–512 байт без управляющих символов.")
            }
        }
        func entries(_ values: [UserMenuEntry], depth: Int) throws {
            guard depth <= 8 else { throw UserCommandError("Допустимо не более 8 уровней меню.") }
            var usedKeys = Set<String>()
            for entry in values {
                count += 1
                guard count <= 512 else { throw UserCommandError("В меню допустимо не более 512 пунктов.") }
                try title(entry.title)
                guard (entry.command != nil) != (entry.children != nil) else {
                    throw UserCommandError("Пункт «\(entry.title)» должен содержать либо command, либо children.")
                }
                if let key = entry.key {
                    guard key.count == 1, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
                          usedKeys.insert(key.lowercased()).inserted else {
                        throw UserCommandError("Клавиша пункта должна быть одной буквой/цифрой и не повторяться в этом меню.")
                    }
                }
                if let command = entry.command { try UserCommandExpander.validate(command) }
                if let children = entry.children {
                    guard !children.isEmpty else { throw UserCommandError("Подменю «\(entry.title)» пустое.") }
                    try entries(children, depth: depth + 1)
                }
            }
        }
        try entries(menu, depth: 1)
        guard associations.count <= 256 else { throw UserCommandError("Допустимо не более 256 ассоциаций.") }
        for association in associations {
            try title(association.title)
            _ = try FileMask(association.mask)
            guard association.execute != nil || association.view != nil || association.edit != nil else {
                throw UserCommandError("Ассоциация «\(association.title)» не содержит команд.")
            }
            for action in [UserCommandAction.execute, .view, .edit] {
                if let command = association.command(for: action) { try UserCommandExpander.validate(command) }
            }
        }
    }

    public func matchingAssociations(for filename: String, action: UserCommandAction) throws -> [UserFileAssociation] {
        var result: [UserFileAssociation] = []
        for association in associations where association.command(for: action) != nil {
            if try FileMask(association.mask).matchesChecked(filename) { result.append(association) }
        }
        return result
    }
}

public struct UserCommandContext: Sendable {
    public let currentFile: URL?
    public let markedFiles: [URL]
    public let activeDirectory: URL
    public let passiveDirectory: URL
    public init(currentFile: URL?, markedFiles: [URL], activeDirectory: URL, passiveDirectory: URL) {
        self.currentFile = currentFile; self.markedFiles = markedFiles
        self.activeDirectory = activeDirectory; self.passiveDirectory = passiveDirectory
    }
}

public enum UserCommandExpander {
    private static let names: Set<String> = ["name", "path", "marked", "active", "passive"]
    public static func validate(_ template: String) throws { _ = try tokens(template) }
    private static func tokens(_ template: String) throws -> [(Range<String.Index>, String)] {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              template.utf8.count <= 16_384, !template.contains("\0") else {
            throw UserCommandError("Команда должна быть непустой, без NUL и не длиннее 16 КиБ.")
        }
        var result: [(Range<String.Index>, String)] = []
        var quote: Character?, escaped = false
        var index = template.startIndex
        let boundaries = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|&;()< >"))
        func boundary(_ character: Character) -> Bool { character.unicodeScalars.allSatisfy { boundaries.contains($0) } }
        while index < template.endIndex {
            let character = template[index]
            let next = template.index(after: index)
            if character == "{" {
                guard let close = template[next...].firstIndex(of: "}") else { throw UserCommandError("Не закрыт параметр команды {…}.") }
                let name = String(template[next..<close])
                guard names.contains(name) else { throw UserCommandError("Неизвестный параметр команды {\(name)}.") }
                let end = template.index(after: close)
                guard quote == nil, !escaped,
                      index == template.startIndex || boundary(template[template.index(before: index)]),
                      end == template.endIndex || boundary(template[end]) else {
                    throw UserCommandError("Параметр {\(name)} должен быть отдельным словом без кавычек и экранирования.")
                }
                result.append((index..<end, name)); index = end; continue
            }
            if escaped { escaped = false }
            else if character == "\\", quote != "'" { escaped = true }
            else if let current = quote { if character == current { quote = nil } }
            else if character == "'" || character == "\"" { quote = character }
            index = next
        }
        if !result.isEmpty, template.contains("$(") || template.contains("$'") || template.contains("$\"") || template.contains("`") || template.contains("<<") || template.contains("\n") || template.contains("\r") {
            throw UserCommandError("Параметры поддерживаются в однострочных командах без подстановки команд и here-document; используйте отдельный скрипт.")
        }
        return result
    }

    public static func expand(_ template: String, context: UserCommandContext) throws -> String {
        let substitutions = try tokens(template)
        var result = "", cursor = template.startIndex
        for (range, name) in substitutions {
            let values: [String]
            switch name {
            case "name", "path":
                guard let file = context.currentFile else { throw UserCommandError("Для {\(name)} выберите текущий файл.") }
                values = [name == "name" ? file.lastPathComponent : file.path]
            case "marked":
                guard !context.markedFiles.isEmpty else { throw UserCommandError("Для {marked} пометьте хотя бы один файл.") }
                values = context.markedFiles.map(\.path)
            case "active": values = [context.activeDirectory.path]
            default: values = [context.passiveDirectory.path]
            }
            result += template[cursor..<range.lowerBound]
            result += try values.map(ShellCommand.quoteArgument).joined(separator: " ")
            guard result.utf8.count <= 1_048_576 else { throw UserCommandError("Развёрнутая команда превышает 1 МиБ.") }
            cursor = range.upperBound
        }
        result += template[cursor...]
        return result
    }
}

public struct LoadedUserMenu: Sendable {
    public let entries: [UserMenuEntry]
    public let source: URL
    public let isLocal: Bool
}

/// Reads are explicit: constructing the store or changing panel directory performs no I/O or execution.
public struct UserCommandStore: Sendable {
    public static let localFilename = ".farformac-menu.json"
    public static var defaultGlobalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FarForMac", isDirectory: true).appendingPathComponent("commands.json")
    }
    public let globalURL: URL
    public init(globalURL: URL = Self.defaultGlobalURL) { self.globalURL = globalURL }
    public func loadGlobal() throws -> UserCommandConfiguration {
        guard let data = try read(globalURL) else { return UserCommandConfiguration() }
        return try UserCommandConfiguration.decode(data)
    }
    public func loadGlobalText() throws -> String? {
        guard let data = try read(globalURL) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { throw UserCommandError("Конфигурация должна быть в UTF-8.") }
        return text
    }
    public func loadMenu(in directory: URL) throws -> LoadedUserMenu {
        let local = directory.appendingPathComponent(Self.localFilename)
        if let data = try read(local) {
            return LoadedUserMenu(entries: try UserCommandConfiguration.decode(data).menu, source: local, isLocal: true)
        }
        return LoadedUserMenu(entries: try loadGlobal().menu, source: globalURL, isLocal: false)
    }
    private func read(_ url: URL) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw UserCommandError("Не удалось открыть конфигурацию \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw UserCommandError("Конфигурация должна быть обычным файлом, а не ссылкой, папкой или каналом.")
        }
        guard info.st_size >= 0, info.st_size <= UserCommandConfiguration.maximumBytes else {
            throw UserCommandError("Конфигурация команд превышает 256 КиБ.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let amount = Darwin.read(descriptor, &buffer, buffer.count)
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                throw UserCommandError("Не удалось прочитать конфигурацию команд.")
            }
            guard data.count + amount <= UserCommandConfiguration.maximumBytes else { throw UserCommandError("Конфигурация команд превышает 256 КиБ.") }
            data.append(contentsOf: buffer.prefix(amount))
        }
        return data
    }

    public func saveGlobalText(_ text: String) throws {
        let data = Data(text.utf8)
        _ = try UserCommandConfiguration.decode(data)
        let directory = globalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw UserCommandError("Папка конфигурации не должна быть символической ссылкой.")
        }
        let temporary = directory.appendingPathComponent(".commands-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UserCommandError("Не удалось создать файл конфигурации.") }
        defer { Darwin.close(descriptor); _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw UserCommandError("Не удалось записать конфигурацию.") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, globalURL.path) == 0 else {
            throw UserCommandError("Не удалось сохранить конфигурацию команд.")
        }
    }

    public static let example = #"""
    {
      "version": 1,
      "menu": [
        { "title": "Показать имя файла", "key": "1", "command": "printf '%s\\n' {name}" },
        { "title": "Каталоги", "children": [
          { "title": "Список активной папки", "command": "ls -la -- {active}" },
          { "title": "Список пассивной папки", "command": "ls -la -- {passive}" }
        ] }
      ],
      "associations": [
        { "title": "Сведения о файле", "mask": "*.txt,*.md", "execute": "file -- {path}" }
      ]
    }
    """#
}
