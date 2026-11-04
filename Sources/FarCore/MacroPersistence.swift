import Foundation
import Darwin

public enum MacroKeyModifier: String, Codable, Hashable, Sendable { case command, option, control, shift }
public struct MacroKeyBinding: Codable, Equatable, Sendable {
    public let key: String
    public let modifiers: Set<MacroKeyModifier>
    public let context: CommandContext
    public let macroID: UUID
    public init(key: String, modifiers: Set<MacroKeyModifier>, context: CommandContext, macroID: UUID) {
        self.key = key; self.modifiers = modifiers; self.context = context; self.macroID = macroID
    }
}
public struct MacroConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var macros: [CommandMacro]
    public var bindings: [MacroKeyBinding]
    public init(version: Int = 1, macros: [CommandMacro] = [], bindings: [MacroKeyBinding] = []) {
        self.version = version; self.macros = macros; self.bindings = bindings
    }
    public func validate() throws {
        guard version == 1, macros.count <= 100, bindings.count <= 200,
              Set(macros.map(\.id)).count == macros.count else { throw MacroError.invalidConfiguration }
        for macro in macros {
            guard !macro.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  macro.name.utf8.count <= 256, !macro.name.utf8.contains(0), macro.steps.count <= MacroController.maximumSteps,
                  macro.steps.allSatisfy({ $0.commandID.isValid && (1...MacroController.maximumSteps).contains($0.repeatCount) }) else { throw MacroError.invalidConfiguration }
            // Each repeat counts against the same budget; check individual bounds before summing.
            guard macro.steps.reduce(0, { $0 + $1.repeatCount }) <= MacroController.maximumSteps else { throw MacroError.invalidConfiguration }
            try macro.conditions?.validate()
        }
        var validated = MacroConfiguration(macros: macros)
        for binding in bindings {
            do { try MacroShortcutPolicy.validate(binding, in: validated) }
            catch { throw MacroError.invalidConfiguration }
            validated.bindings.append(binding)
        }
    }
}

/// Data-only JSON: loading never registers commands, binds keys or runs macros.
public enum MacroPersistence {
    public static let maximumBytes = 2_000_000
    public static func encode(_ configuration: MacroConfiguration) throws -> Data {
        try configuration.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= maximumBytes else { throw MacroError.invalidConfiguration }
        return data
    }
    public static func decode(_ data: Data) throws -> MacroConfiguration {
        guard data.count <= maximumBytes else { throw MacroError.invalidConfiguration }
        let result = try JSONDecoder().decode(MacroConfiguration.self, from: data)
        try result.validate(); return result
    }
    public static func save(_ configuration: MacroConfiguration, to url: URL) throws {
        guard url.isFileURL else { throw MacroError.invalidConfiguration }
        try encode(configuration).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func load(from url: URL) throws -> MacroConfiguration {
        guard url.isFileURL else { throw MacroError.invalidConfiguration }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw MacroError.invalidConfiguration }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumBytes else { throw MacroError.invalidConfiguration }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw MacroError.invalidConfiguration }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw MacroError.invalidConfiguration }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try decode(data)
    }
}
