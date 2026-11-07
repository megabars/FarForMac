import Foundation
import Darwin

public struct UserCommandError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public enum UserCommandAction: String, Codable, CaseIterable, Sendable {
    case execute, view, edit, alternateExecute, alternateView, alternateEdit
}

public struct UserMenuEntry: Codable, Equatable, Sendable {
    public var title: String
    public var command: String?
    public var children: [UserMenuEntry]?
    public var key: String?
    public var separator: Bool?
    public var farSyntax: Bool?
    public init(title: String, command: String? = nil, children: [UserMenuEntry]? = nil, key: String? = nil, separator: Bool = false, farSyntax: Bool = false) {
        self.title = title; self.command = command; self.children = children; self.key = key
        self.separator = separator ? true : nil
        self.farSyntax = farSyntax ? true : nil
    }
}

public struct UserFileAssociation: Codable, Equatable, Sendable {
    public var title: String
    public var mask: String
    public var execute: String?
    public var view: String?
    public var edit: String?
    public var alternateExecute: String?
    public var alternateView: String?
    public var alternateEdit: String?
    public var farSyntax: Bool?
    public init(title: String, mask: String, execute: String? = nil, view: String? = nil, edit: String? = nil,
                alternateExecute: String? = nil, alternateView: String? = nil, alternateEdit: String? = nil,
                farSyntax: Bool = false) {
        self.title = title; self.mask = mask; self.execute = execute; self.view = view; self.edit = edit
        self.alternateExecute = alternateExecute; self.alternateView = alternateView; self.alternateEdit = alternateEdit
        self.farSyntax = farSyntax ? true : nil
    }
    public func command(for action: UserCommandAction) -> String? {
        switch action {
        case .execute: return execute; case .view: return view; case .edit: return edit
        case .alternateExecute: return alternateExecute; case .alternateView: return alternateView; case .alternateEdit: return alternateEdit
        }
    }
}

public struct UserAssociationCandidate: Equatable, Sendable {
    public let association: UserFileAssociation
    public let title: String
    public let template: String
}

public struct UserAssociationResolution: Equatable, Sendable {
    public let hasMatchingAction: Bool
    public let candidates: [UserAssociationCandidate]
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
                let object = try keys(entry, allowed: ["title", "command", "children", "key", "separator", "farSyntax"])
                if let children = object["children"] { try menu(children) }
            }
        }
        let root = try keys(value, allowed: ["version", "menu", "associations"])
        if let entries = root["menu"] { try menu(entries) }
        if let entries = root["associations"] as? [Any] {
            for entry in entries { _ = try keys(entry, allowed: ["title", "mask", "execute", "view", "edit", "alternateExecute", "alternateView", "alternateEdit", "farSyntax"]) }
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
                if entry.farSyntax != true || entry.separator != true || !entry.title.isEmpty { try title(entry.title) }
                if entry.separator == true {
                    guard entry.command == nil, entry.children == nil, entry.key == nil else {
                        throw UserCommandError("Разделитель меню не может содержать команду, подменю или клавишу.")
                    }
                    continue
                }
                guard (entry.command != nil) != (entry.children != nil) else {
                    throw UserCommandError("Пункт «\(entry.title)» должен содержать либо command, либо children.")
                }
                if let key = entry.key {
                    let characterKey = key.count == 1 && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
                    let farKey = entry.farSyntax == true && key.count == 1 && !key.unicodeScalars.contains(where: {
                        CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
                    })
                    let functionKey = key.uppercased().hasPrefix("F") && Int(key.dropFirst()).map { (1...24).contains($0) && "F\($0)" == key.uppercased() } == true
                    guard characterKey || functionKey || farKey,
                          entry.farSyntax == true || usedKeys.insert(key.lowercased()).inserted else {
                        throw UserCommandError("Клавиша пункта должна быть одной буквой/цифрой или F1–F24 и не повторяться в этом меню.")
                    }
                }
                if let command = entry.command {
                    if entry.farSyntax == true { try FarMenuImporter.validateCommandBlock(command) }
                    else { try UserCommandExpander.validate(command) }
                }
                if let children = entry.children, !children.isEmpty {
                    try entries(children, depth: depth + 1)
                }
            }
        }
        try entries(menu, depth: 1)
        guard associations.count <= 256 else { throw UserCommandError("Допустимо не более 256 ассоциаций.") }
        for association in associations {
            if association.farSyntax != true || !association.title.isEmpty { try title(association.title) }
            _ = try FileMask(association.mask)
            guard UserCommandAction.allCases.contains(where: { association.command(for: $0) != nil }) else {
                throw UserCommandError("Ассоциация «\(association.title)» не содержит команд.")
            }
            for action in UserCommandAction.allCases {
                guard let command = association.command(for: action) else { continue }
                if association.farSyntax == true {
                    try FarMenuImporter.validateCommandBlock(command)
                    guard !command.contains(where: \.isNewline) else {
                        throw UserCommandError("Ассоциация FAR должна содержать одну команду.")
                    }
                } else {
                    try UserCommandExpander.validate(FarMenuMetasymbols.associationTemplate(command,
                        captures: FarMenuMetasymbols.referencedCaptures(in: command)))
                }
            }
        }
    }

    /// FAR consumes a matching association action even when all conditions are false.
    public func resolveAssociations(for filename: String, action: UserCommandAction,
                                    context: UserCommandContext, commands: InternalCommandState) throws -> UserAssociationResolution {
        var matched = false
        var candidates: [UserAssociationCandidate] = []
        for association in associations {
            guard let source = association.command(for: action),
                  let captures = try FileMask(association.mask).associationCaptures(filename) else { continue }
            matched = true
            let isFar = association.farSyntax == true
            let template = try isFar
                ? FarMenuMetasymbols.command(source, context: context, variables: captures)
                : FarMenuMetasymbols.associationTemplate(source, captures: captures)
            let potentialCondition = template.drop(while: { $0.isWhitespace || $0 == "@" })
            let firstWord = potentialCondition.prefix(while: { !$0.isWhitespace })
            let commandTitle: String?
            if firstWord.lowercased() == "if" {
                let preview = try UserCommandExpander.preview(template, context: context)
                guard let command = try commands.conditionallyExecutable(preview, currentDirectory: context.activeDirectory) else { continue }
                commandTitle = command
            } else {
                commandTitle = nil
            }
            let title: String
            if association.title.isEmpty {
                title = commandTitle ?? (isFar ? FarMenuMetasymbols.title(source, context: context, variables: captures) : source)
            } else if isFar {
                title = FarMenuMetasymbols.title(association.title, context: context, variables: captures)
            } else {
                title = association.title
            }
            candidates.append(UserAssociationCandidate(association: association, title: title, template: template))
        }
        return UserAssociationResolution(hasMatchingAction: matched, candidates: candidates)
    }

    public func associationCandidates(for filename: String, action: UserCommandAction,
                                      context: UserCommandContext, commands: InternalCommandState) throws -> [UserAssociationCandidate] {
        try resolveAssociations(for: filename, action: action, context: context, commands: commands).candidates
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
    public let passiveCurrentFile: URL?
    public let passiveMarkedFiles: [URL]
    public let activePanelIsLeft: Bool
    public let activeDescriptionEncoding: FileDescriptionEncoding
    public let passiveDescriptionEncoding: FileDescriptionEncoding
    public init(currentFile: URL?, markedFiles: [URL], activeDirectory: URL, passiveDirectory: URL,
                passiveCurrentFile: URL? = nil, passiveMarkedFiles: [URL] = [], activePanelIsLeft: Bool = true,
                activeDescriptionEncoding: FileDescriptionEncoding = .utf8, passiveDescriptionEncoding: FileDescriptionEncoding = .utf8) {
        self.currentFile = currentFile; self.markedFiles = markedFiles
        self.activeDirectory = activeDirectory; self.passiveDirectory = passiveDirectory
        self.passiveCurrentFile = passiveCurrentFile; self.passiveMarkedFiles = passiveMarkedFiles
        self.activePanelIsLeft = activePanelIsLeft
        self.activeDescriptionEncoding = activeDescriptionEncoding
        self.passiveDescriptionEncoding = passiveDescriptionEncoding
    }
    public func replacingCurrentFile(_ file: URL?, directory: URL, markedFiles: [URL]? = nil) -> Self {
        Self(currentFile: file, markedFiles: markedFiles ?? self.markedFiles, activeDirectory: directory, passiveDirectory: passiveDirectory,
             passiveCurrentFile: passiveCurrentFile, passiveMarkedFiles: passiveMarkedFiles, activePanelIsLeft: activePanelIsLeft,
             activeDescriptionEncoding: activeDescriptionEncoding, passiveDescriptionEncoding: passiveDescriptionEncoding)
    }

}

public struct LoadedUserMenu: Sendable {
    public enum Location: Equatable, Sendable { case local, installation, profile }
    public let entries: [UserMenuEntry]
    public let source: URL
    public let location: Location
    public var isLocal: Bool { location == .local }
    public var isFarMenu: Bool { configuration == nil }
    fileprivate let configuration: UserCommandConfiguration?
    fileprivate let originalData: Data?
}

/// Reads are explicit: constructing the store or changing panel directory performs no I/O or execution.
public struct UserCommandStore: Sendable {
    public static let localFilename = ".farformac-menu.json"
    public static let farMenuFilename = "FarMenu.ini"
    public static var defaultGlobalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FarForMac", isDirectory: true).appendingPathComponent("commands.json")
    }
    public let globalURL: URL
    public let installationMenuDirectory: URL?
    public init(globalURL: URL = Self.defaultGlobalURL, installationMenuDirectory: URL? = nil) {
        self.globalURL = globalURL
        self.installationMenuDirectory = installationMenuDirectory
    }
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
        if let local = try loadLocalMenu(in: directory) { return local }
        return try loadMainMenu()
    }
    public func loadLocalMenu(in directory: URL) throws -> LoadedUserMenu? {
        if let native = try loadFarMenu(in: directory, location: .local) { return native }
        let url = directory.appendingPathComponent(Self.localFilename)
        guard let data = try read(url) else { return nil }
        let config = try UserCommandConfiguration.decode(data)
        return LoadedUserMenu(entries: config.menu, source: url, location: .local, configuration: config, originalData: data)
    }
    public func loadMainMenu() throws -> LoadedUserMenu {
        if let installationMenuDirectory, let installation = try loadFarMenu(in: installationMenuDirectory, location: .installation) {
            return installation
        }
        return try loadProfileMenu()
    }
    public func loadProfileMenu() throws -> LoadedUserMenu {
        if let native = try loadFarMenu(in: globalURL.deletingLastPathComponent(), location: .profile) { return native }
        let data = try read(globalURL)
        let config = try data.map(UserCommandConfiguration.decode) ?? UserCommandConfiguration()
        return LoadedUserMenu(entries: config.menu, source: globalURL, location: .profile, configuration: config, originalData: data)
    }
    public func loadParentMenu(of menu: LoadedUserMenu) throws -> LoadedUserMenu {
        guard menu.isLocal else { return try loadProfileMenu() }
        var current = menu.source.deletingLastPathComponent()
        while current.path != "/" {
            current.deleteLastPathComponent()
            if let parent = try loadLocalMenu(in: current) { return parent }
        }
        return try loadMainMenu()
    }
    public func nextMenu(after menu: LoadedUserMenu, in directory: URL) throws -> LoadedUserMenu {
        switch menu.location {
        case .local: return try loadMainMenu()
        case .installation: return try loadProfileMenu()
        case .profile: return try loadMenu(in: directory)
        }
    }
    private func loadFarMenu(in directory: URL, location: LoadedUserMenu.Location) throws -> LoadedUserMenu? {
        let url = directory.appendingPathComponent(Self.farMenuFilename)
        guard let data = try read(url) else { return nil }
        return try farMenu(from: data, at: url, location: location)
    }
    private func farMenu(from data: Data, at url: URL, location: LoadedUserMenu.Location) throws -> LoadedUserMenu {
        let entries = try FarMenuImporter.parseNative(data).menu
        return LoadedUserMenu(entries: entries, source: url, location: location, configuration: nil, originalData: data)
    }
    public func farMenuText(_ original: LoadedUserMenu) throws -> String {
        guard original.isFarMenu, let data = original.originalData else {
            throw UserCommandError("Ожидается текстовый источник FarMenu.ini.")
        }
        return try FarMenuImporter.decodeText(data)
    }
    @discardableResult
    public func saveFarMenuText(_ text: String, replacing original: LoadedUserMenu) throws -> LoadedUserMenu {
        guard original.isFarMenu, original.source.lastPathComponent == Self.farMenuFilename else {
            throw UserCommandError("Ожидается текстовый источник FarMenu.ini.")
        }
        let data = try FarMenuImporter.encodeText(text, original: original.originalData)
        let updated = try farMenu(from: data, at: original.source, location: original.location)
        try saveMenuData(data, replacing: original)
        return updated
    }
    public func saveMenu(_ entries: [UserMenuEntry], replacing original: LoadedUserMenu) throws -> LoadedUserMenu {
        if original.isFarMenu {
            let oldText = try farMenuText(original)
            let eol = oldText.contains("\r\n") ? "\r\n" : oldText.contains("\r") ? "\r" : "\n"
            try UserCommandConfiguration(menu: entries).validate()
            return try saveFarMenuText(FarMenuImporter.serialize(entries, lineEnding: eol), replacing: original)
        }
        guard original.isLocal ? original.source.lastPathComponent == Self.localFilename : original.source == globalURL else {
            throw UserCommandError("Неизвестный источник пользовательского меню.")
        }
        guard var config = original.configuration else { throw UserCommandError("Отсутствует конфигурация JSON.") }
        config.menu = entries
        try config.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        _ = try UserCommandConfiguration.decode(data)
        try saveMenuData(data, replacing: original)
        return LoadedUserMenu(entries: entries, source: original.source, location: original.location,
            configuration: config, originalData: data)
    }
    private func saveMenuData(_ data: Data, replacing original: LoadedUserMenu) throws {
        try save(data, to: original.source) {
            guard try read(original.source) == original.originalData else {
                throw UserCommandError("Файл меню изменился. Откройте меню заново.")
            }
        }
    }
    public func importFarMenu(at url: URL) throws -> FarMenuImportResult {
        guard let data = try read(url) else { throw UserCommandError("Файл меню не найден.") }
        return try FarMenuImporter.parseNative(data)
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
        try save(data, to: globalURL)
    }
    private func save(_ data: Data, to destination: URL, verify: () throws -> Void = {}) throws {
        let directory = destination.deletingLastPathComponent()
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
        guard fsync(descriptor) == 0 else { throw UserCommandError("Не удалось сохранить конфигурацию команд.") }
        try verify()
        guard rename(temporary.path, destination.path) == 0 else {
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
          { "title": "Список пассивной папки", "command": "ls -la -- {passive}" },
          { "title": "Ввести текст", "command": "printf '%s\\n' {input:Текст|Пример}" },
          { "title": "Список выбранных путей", "command": "cat {list}" }
        ] }
      ],
      "associations": [
        { "title": "Сведения о файле", "mask": "*.txt,*.md", "execute": "file -- {path}", "alternateView": "cat -- {path}" }
      ]
    }
    """#
}
