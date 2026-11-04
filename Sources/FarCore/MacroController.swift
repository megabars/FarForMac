import Foundation

public struct MacroStep: Codable, Equatable, Sendable {
    public let commandID: CommandID
    public let context: CommandContext
    public init(commandID: CommandID, context: CommandContext) { self.commandID = commandID; self.context = context }
}
public struct CommandMacro: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var steps: [MacroStep]
    public init(id: UUID = UUID(), name: String, steps: [MacroStep]) { self.id = id; self.name = name; self.steps = steps }
}
public enum MacroError: Error, Equatable {
    case busy, notRecording, tooManySteps, invalidConfiguration, cancelled
}
public struct MacroFailure: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let commandID: CommandID?
    public let message: String
}

@MainActor public final class MacroController {
    public nonisolated static let maximumSteps = 256
    public private(set) var isRecording = false
    public private(set) var isPlaying = false
    public private(set) var errors: [MacroFailure] = []
    private let registry: CommandRegistry
    private let contextProvider: () -> CommandContext
    private var steps: [MacroStep] = []
    private var stopped = false
    public init(registry: CommandRegistry, contextProvider: @escaping () -> CommandContext) {
        self.registry = registry; self.contextProvider = contextProvider
    }
    public func startRecording() throws {
        guard !isPlaying, !isRecording else { throw MacroError.busy }
        steps = []; isRecording = true
    }
    public func stopRecording(name: String) throws -> CommandMacro {
        do {
            guard isRecording else { throw MacroError.notRecording }
            isRecording = false
            let macro = CommandMacro(name: name, steps: steps)
            steps = []
            try MacroConfiguration(macros: [macro]).validate()
            return macro
        } catch { remember(error, commandID: nil); throw error }
    }
    public func cancelRecording() { isRecording = false; steps = [] }
    /// Use this entry point for user command dispatch so successful commands are recorded.
    public func execute(_ id: CommandID, in context: CommandContext) throws {
        guard !isPlaying else { throw MacroError.busy }
        if isRecording, registry.descriptor(for: id)?.recordable == true, steps.count >= Self.maximumSteps {
            isRecording = false; steps = []
            let error = MacroError.tooManySteps; remember(error, commandID: id); throw error
        }
        do {
            try registry.execute(id, in: context)
            if isRecording, registry.descriptor(for: id)?.recordable == true { steps.append(MacroStep(commandID: id, context: context)) }
        } catch { remember(error, commandID: id); throw error }
    }
    public func stop() { stopped = true }
    public func clearErrors() { errors = [] }
    public func play(_ macro: CommandMacro) async throws {
        var current: CommandID?
        do {
            guard !isRecording, !isPlaying else { throw MacroError.busy }
            try MacroConfiguration(macros: [macro]).validate()
            // Reject an invalid imported sequence before any handler can run.
            // Re-check at dispatch too, because registrations can change while yielding.
            for step in macro.steps {
                current = step.commandID
                guard let descriptor = registry.descriptor(for: step.commandID) else { throw CommandRegistryError.unknownCommand }
                guard descriptor.recordable else { throw CommandRegistryError.notRecordable }
                guard descriptor.contexts.contains(step.context) else { throw CommandRegistryError.contextMismatch }
            }
            current = nil
            isPlaying = true; stopped = false
            defer { isPlaying = false }
            for step in macro.steps {
                // Yield to UI events between every command, including before the first.
                try await Task.sleep(nanoseconds: 1_000_000)
                guard !stopped, !Task.isCancelled else { throw MacroError.cancelled }
                current = step.commandID
                guard contextProvider() == step.context else { throw CommandRegistryError.contextMismatch }
                guard registry.descriptor(for: step.commandID)?.recordable == true else { throw CommandRegistryError.notRecordable }
                try registry.execute(step.commandID, in: step.context)
            }
        } catch { remember(error, commandID: current); throw error }
    }
    private func remember(_ error: Error, commandID: CommandID?) {
        errors.insert(MacroFailure(id: UUID(), date: Date(), commandID: commandID, message: String(String(describing: error).prefix(1024))), at: 0)
        if errors.count > 100 { errors.removeLast(errors.count - 100) }
    }
}
