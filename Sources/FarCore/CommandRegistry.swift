import Foundation

public enum CommandContext: String, Codable, CaseIterable, Hashable, Sendable {
    case panel, editor, viewer, dialog
}

public struct CommandID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var isValid: Bool {
        !rawValue.isEmpty && rawValue.utf8.count <= 128 && rawValue.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }
}

public enum CommandRegistryError: Error, Equatable {
    case invalidCommand, duplicateCommand, unknownCommand, contextMismatch, notRecordable
}

public struct CommandDescriptor: Equatable, Sendable {
    public let id: CommandID
    public let title: String
    public let contexts: Set<CommandContext>
    public let recordable: Bool
}

/// Dispatches semantic commands only. Handlers retain normal UI confirmation flows.
@MainActor public final class CommandRegistry {
    private struct Entry { let descriptor: CommandDescriptor; let handler: () throws -> Void }
    private var entries: [CommandID: Entry] = [:]
    public init() {}
    public var descriptors: [CommandDescriptor] { entries.values.map(\.descriptor).sorted { $0.id.rawValue < $1.id.rawValue } }
    public func descriptor(for id: CommandID) -> CommandDescriptor? { entries[id]?.descriptor }
    public func register(id: CommandID, title: String, contexts: Set<CommandContext>, recordable: Bool = true, handler: @escaping () throws -> Void) throws {
        guard id.isValid, !title.isEmpty, title.utf8.count <= 256, !contexts.isEmpty else { throw CommandRegistryError.invalidCommand }
        guard entries[id] == nil else { throw CommandRegistryError.duplicateCommand }
        entries[id] = Entry(descriptor: CommandDescriptor(id: id, title: title, contexts: contexts, recordable: recordable), handler: handler)
    }
    public func unregister(_ id: CommandID) { entries.removeValue(forKey: id) }
    public func execute(_ id: CommandID, in context: CommandContext) throws {
        guard let entry = entries[id] else { throw CommandRegistryError.unknownCommand }
        guard entry.descriptor.contexts.contains(context) else { throw CommandRegistryError.contextMismatch }
        try entry.handler()
    }
}
