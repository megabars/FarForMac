import Foundation

/// A data snapshot, supplied by the active UI. Unknown fields fail closed when required.
public struct MacroEnvironment: Equatable, Sendable {
    public let context: CommandContext
    public let fileName: String?
    public let isDirectory: Bool?
    public let hasSelection: Bool?
    public let isEditable: Bool?
    public init(context: CommandContext, fileName: String? = nil, isDirectory: Bool? = nil,
                hasSelection: Bool? = nil, isEditable: Bool? = nil) {
        self.context = context; self.fileName = fileName; self.isDirectory = isDirectory
        self.hasSelection = hasSelection; self.isEditable = isEditable
    }
}

public enum MacroRequirement: String, Codable, CaseIterable, Sendable {
    case any, present, absent
    fileprivate func matches(_ value: Bool?) -> Bool {
        switch self { case .any: return true; case .present: return value == true; case .absent: return value == false }
    }
}
public enum MacroEntryKind: String, Codable, CaseIterable, Sendable { case any, file, directory }

/// Activation conditions are evaluated before the first command, never as executable code.
/// They intentionally do not test every step: a selection command may change its own condition.
public struct MacroConditions: Codable, Equatable, Sendable {
    public var fileMask: String?
    public var entryKind: MacroEntryKind
    public var selection: MacroRequirement
    public var editable: MacroRequirement
    public init(fileMask: String? = nil, entryKind: MacroEntryKind = .any,
                selection: MacroRequirement = .any, editable: MacroRequirement = .any) {
        self.fileMask = fileMask; self.entryKind = entryKind; self.selection = selection; self.editable = editable
    }
    public func validate() throws {
        if let fileMask {
            guard !fileMask.utf8.contains(0) else { throw MacroError.invalidConfiguration }
            _ = try FileMask(fileMask)
        }
    }
    public func matches(_ environment: MacroEnvironment) throws -> Bool {
        try validate()
        guard selection.matches(environment.hasSelection), editable.matches(environment.isEditable) else { return false }
        if entryKind != .any {
            guard let directory = environment.isDirectory, directory == (entryKind == .directory) else { return false }
        }
        if let fileMask {
            guard let name = environment.fileName, try FileMask(fileMask).matchesChecked(name) else { return false }
        }
        return true
    }
}
