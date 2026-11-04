import Foundation
import Testing
@testable import FarCore

@Suite @MainActor struct MacroTests {
    @Test func recordingUsesOnlySuccessfulRecordableSemanticCommands() throws {
        let registry = CommandRegistry()
        var count = 0
        try registry.register(id: "panel.next", title: "Next", contexts: [.panel]) { count += 1 }
        try registry.register(id: "shell.run", title: "Shell", contexts: [.panel], recordable: false) { count += 1 }
        let controller = MacroController(registry: registry) { .panel }
        try controller.startRecording()
        try controller.execute("panel.next", in: .panel)
        try controller.execute("shell.run", in: .panel)
        #expect(throws: CommandRegistryError.contextMismatch) { try controller.execute("panel.next", in: .editor) }
        let macro = try controller.stopRecording(name: "Navigation")
        #expect(count == 2)
        #expect(macro.steps == [MacroStep(commandID: "panel.next", context: .panel)])
        #expect(controller.errors.count == 1)
        #expect(throws: CommandRegistryError.duplicateCommand) { try registry.register(id: "panel.next", title: "Duplicate", contexts: [.panel]) {} }
    }
    @Test func playbackStopsAtChangedContextAndHandlerErrors() async throws {
        let registry = CommandRegistry()
        var context = CommandContext.panel
        var count = 0
        try registry.register(id: "panel.open", title: "Open", contexts: [.panel]) { count += 1; context = .dialog }
        let controller = MacroController(registry: registry) { context }
        let macro = CommandMacro(name: "Open", steps: Array(repeating: MacroStep(commandID: "panel.open", context: .panel), count: 3))
        do { try await controller.play(macro); Issue.record("Expected context mismatch") } catch { #expect(error as? CommandRegistryError == .contextMismatch) }
        #expect(count == 1)
        #expect(!controller.isPlaying)
        #expect(controller.errors.count == 1)
        context = .panel
        try registry.register(id: "panel.fail", title: "Fail", contexts: [.panel]) { throw MacroError.invalidConfiguration }
        do { try await controller.play(CommandMacro(name: "Fail", steps: [MacroStep(commandID: "panel.fail", context: .panel), macro.steps[0]])); Issue.record("Expected failure") } catch {}
        #expect(count == 1)
    }
    @Test func stopIsResponsiveBetweenCommandsAndErrorHistoryIsBounded() async throws {
        let registry = CommandRegistry()
        var count = 0
        let controller = MacroController(registry: registry) { .panel }
        try registry.register(id: "panel.next", title: "Next", contexts: [.panel]) { count += 1; controller.stop() }
        do { try await controller.play(CommandMacro(name: "Stop", steps: Array(repeating: MacroStep(commandID: "panel.next", context: .panel), count: 256))); Issue.record("Expected stop") } catch { #expect(error as? MacroError == .cancelled) }
        #expect(count == 1)
        for _ in 0..<120 { try? controller.execute("unknown", in: .panel) }
        #expect(controller.errors.count == 100)
    }
    @Test func persistenceValidatesBoundsBindingsAndNeverExecutes() throws {
        let macro = CommandMacro(name: "Test", steps: [MacroStep(commandID: "panel.next", context: .panel)])
        let binding = MacroKeyBinding(key: "n", modifiers: [.control], context: .panel, macroID: macro.id)
        let config = MacroConfiguration(macros: [macro], bindings: [binding])
        #expect(try MacroPersistence.decode(MacroPersistence.encode(config)) == config)
        #expect(throws: MacroError.invalidConfiguration) { try MacroConfiguration(macros: [macro], bindings: [binding, binding]).validate() }
        #expect(throws: MacroError.invalidConfiguration) { try MacroConfiguration(version: 2).validate() }
        #expect(throws: MacroError.invalidConfiguration) { try MacroPersistence.decode(Data(repeating: 32, count: MacroPersistence.maximumBytes + 1)) }
        #expect(throws: MacroError.invalidConfiguration) { try MacroConfiguration(macros: [CommandMacro(name: "Bad", steps: Array(repeating: macro.steps[0], count: 257))]).validate() }
        #expect(throws: MacroError.invalidConfiguration) { try MacroConfiguration(macros: [macro], bindings: [MacroKeyBinding(key: "$(run)", modifiers: [.control], context: .panel, macroID: macro.id)]).validate() }
    }
    @Test func forgedStepsCannotInvokeNonrecordableCommandsAndTaskCancellationStops() async throws {
        let registry = CommandRegistry()
        var count = 0
        try registry.register(id: "shell.run", title: "Shell", contexts: [.panel], recordable: false) { count += 1 }
        let controller = MacroController(registry: registry) { .panel }
        let forged = CommandMacro(name: "Imported", steps: [MacroStep(commandID: "shell.run", context: .panel)])
        do { try await controller.play(forged); Issue.record("Expected nonrecordable rejection") }
        catch { #expect(error as? CommandRegistryError == .notRecordable) }
        #expect(count == 0)
        try registry.register(id: "panel.next", title: "Next", contexts: [.panel]) { count += 1 }
        let task = Task { try await controller.play(CommandMacro(name: "Cancelled", steps: [MacroStep(commandID: "panel.next", context: .panel)])) }
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") } catch {}
        #expect(count == 0)
        #expect(!controller.isPlaying)
    }
    @Test func recordingOverflowDiscardsPartialMacro() throws {
        let registry = CommandRegistry()
        var count = 0
        try registry.register(id: "panel.next", title: "Next", contexts: [.panel]) { count += 1 }
        let controller = MacroController(registry: registry) { .panel }
        try controller.startRecording()
        for _ in 0..<MacroController.maximumSteps { try controller.execute("panel.next", in: .panel) }
        #expect(throws: MacroError.tooManySteps) { try controller.execute("panel.next", in: .panel) }
        #expect(!controller.isRecording)
        #expect(count == MacroController.maximumSteps)
        #expect(throws: MacroError.notRecording) { try controller.stopRecording(name: "Truncated") }
    }

    @Test func filePersistenceRoundTripsAndRejectsSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("macros.json")
        let configuration = MacroConfiguration(macros: [CommandMacro(name: "Saved", steps: [])])
        try MacroPersistence.save(configuration, to: url)
        #expect(try MacroPersistence.load(from: url) == configuration)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: MacroError.invalidConfiguration) { try MacroPersistence.load(from: link) }
    }

    @Test func malformedImportedSequencesFailBeforeAnyHandlerAndRememberValidationErrors() async throws {
        let registry = CommandRegistry()
        var count = 0
        try registry.register(id: "panel.next", title: "Next", contexts: [.panel]) { count += 1 }
        try registry.register(id: "panel.hidden", title: "Hidden", contexts: [.panel], recordable: false) { count += 1 }
        let controller = MacroController(registry: registry) { .panel }
        let first = MacroStep(commandID: "panel.next", context: .panel)
        for (bad, expected) in [
            (MacroStep(commandID: "missing", context: .panel), CommandRegistryError.unknownCommand),
            (MacroStep(commandID: "panel.hidden", context: .panel), .notRecordable),
            (MacroStep(commandID: "panel.next", context: .editor), .contextMismatch)
        ] {
            do { try await controller.play(CommandMacro(name: "Imported", steps: [first, bad])); Issue.record("Expected preflight rejection") }
            catch { #expect(error as? CommandRegistryError == expected) }
            #expect(count == 0)
            #expect(controller.errors.first?.commandID == bad.commandID)
            #expect(!controller.isPlaying)
        }
        do { try await controller.play(CommandMacro(name: "", steps: [first])); Issue.record("Expected validation failure") }
        catch { #expect(error as? MacroError == .invalidConfiguration) }
        #expect(controller.errors.count == 4)
        #expect(controller.errors.first?.commandID == nil)
        try controller.startRecording()
        try controller.execute("panel.next", in: .panel)
        #expect(throws: MacroError.invalidConfiguration) { try controller.stopRecording(name: "") }
        #expect(controller.errors.count == 5)
        #expect(!controller.isRecording)
    }

}
