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
        let binding = MacroKeyBinding(key: "n", modifiers: [.command, .control], context: .panel, macroID: macro.id)
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

    @Test func shortcutPolicyAcceptsCustomChordsAndCanonicalizesPhysicalKeys() throws {
        let macro = CommandMacro(name: "Navigate", steps: [MacroStep(commandID: "panel.next", context: .panel)])
        for key in ["N", " 7 ", ";", "f14", "F20"] {
            let binding = MacroKeyBinding(key: key, modifiers: [.command, .control], context: .panel, macroID: macro.id)
            try MacroConfiguration(macros: [macro], bindings: [binding]).validate()
        }
        #expect(MacroShortcutPolicy.canonicalKey(" F14 ") == "f14")
        #expect(MacroShortcutPolicy.canonicalKey("ж") == nil)
        #expect(MacroShortcutPolicy.canonicalKey("f21") == nil)
        #expect(MacroShortcutPolicy.canonicalKey("enter") == nil)
    }
    @Test func shortcutPolicyProtectsTypingNativeEditingSystemAndAutomationShortcuts() throws {
        let id = UUID()
        let typingFlags: [Set<MacroKeyModifier>] = [[], [.shift], [.option], [.control], [.control, .shift], [.control, .option]]
        for flags in typingFlags {
            #expect(throws: MacroBindingError.typingShortcut) {
                try MacroShortcutPolicy.validate(MacroKeyBinding(key: "n", modifiers: flags, context: .editor, macroID: id))
            }
        }
        for key in ["a", "c", "v", "x", "z", "s", "w"] {
            #expect(throws: MacroBindingError.nativeEditingShortcut) {
                try MacroShortcutPolicy.validate(MacroKeyBinding(key: key, modifiers: [.command], context: .editor, macroID: id))
            }
        }
        let systemKeys: [(String, Set<MacroKeyModifier>)] = [("q", [.command, .control]), ("3", [.command, .shift]), ("4", [.command, .control, .shift]), ("8", [.command, .option]), ("f5", [.command, .option])]
        for (key, flags) in systemKeys {
            #expect(throws: MacroBindingError.systemShortcut) {
                try MacroShortcutPolicy.validate(MacroKeyBinding(key: key, modifiers: flags, context: .panel, macroID: id))
            }
        }
        #expect(throws: MacroBindingError.nativeEditingShortcut) {
            try MacroShortcutPolicy.validate(MacroKeyBinding(key: "v", modifiers: [.command, .option, .shift], context: .editor, macroID: id))
        }
        for key in ["p", "r", "."] {
            #expect(throws: MacroBindingError.applicationShortcut) {
                try MacroShortcutPolicy.validate(MacroKeyBinding(key: key, modifiers: [.command, .control], context: .panel, macroID: id))
            }
        }
    }
    @Test func bindingValidationChecksMacroContextAndDetectsCanonicalDuplicates() throws {
        let panel = CommandMacro(name: "Panel", steps: [MacroStep(commandID: "panel.next", context: .panel)])
        let editor = CommandMacro(name: "Editor", steps: [MacroStep(commandID: "editor.next", context: .editor)])
        func binding(_ key: String, _ macro: CommandMacro, _ context: CommandContext) -> MacroKeyBinding {
            MacroKeyBinding(key: key, modifiers: [.command, .control], context: context, macroID: macro.id)
        }
        let sameKeyDifferentContexts = MacroConfiguration(macros: [panel, editor], bindings: [binding("n", panel, .panel), binding("n", editor, .editor)])
        try sameKeyDifferentContexts.validate()
        #expect(throws: MacroError.invalidConfiguration) { try MacroConfiguration(macros: [panel, editor], bindings: [binding("n", panel, .editor)]).validate() }
        #expect(throws: MacroError.invalidConfiguration) { try MacroConfiguration(macros: [panel], bindings: [binding("n", panel, .panel), binding("N", panel, .panel)]).validate() }
        let empty = CommandMacro(name: "Empty", steps: [])
        #expect(throws: MacroError.invalidConfiguration) { try MacroConfiguration(macros: [empty], bindings: [binding("n", empty, .panel)]).validate() }
        let other = CommandMacro(name: "Other", steps: panel.steps)
        let configuration = MacroConfiguration(macros: [panel, other], bindings: [binding("n", panel, .panel)])
        try MacroShortcutPolicy.validate(binding("N", panel, .panel), in: configuration, replacingMacro: true)
        #expect(throws: MacroBindingError.duplicateBinding) { try MacroShortcutPolicy.validate(binding("N", other, .panel), in: configuration, replacingMacro: true) }
    }
    @Test func assignmentPreflightChecksTheWholeMacroWithoutRunningHandlers() throws {
        let registry = CommandRegistry()
        var executed = false
        try registry.register(id: "panel.next", title: "Next", contexts: [.panel]) { executed = true }
        let controller = MacroController(registry: registry) { .panel }
        let macro = CommandMacro(name: "Valid", steps: [MacroStep(commandID: "panel.next", context: .panel)])
        try controller.validate(macro, in: .panel)
        #expect(throws: CommandRegistryError.contextMismatch) { try controller.validate(macro, in: .editor) }
        let bad = CommandMacro(name: "Imported", steps: macro.steps + [MacroStep(commandID: "missing", context: .panel)])
        #expect(throws: CommandRegistryError.unknownCommand) { try controller.validate(bad, in: .panel) }
        #expect(!executed)
    }

    @Test func conditionsUseFilenameKindAndSelectionAndRejectUnknownState() throws {
        let conditions = MacroConditions(fileMask: "*.txt,*.md|secret*", entryKind: .file, selection: .present, editable: .present)
        #expect(try conditions.matches(MacroEnvironment(context: .editor, fileName: "notes.md", isDirectory: false, hasSelection: true, isEditable: true)))
        for environment in [
            MacroEnvironment(context: .editor, fileName: "secret.txt", isDirectory: false, hasSelection: true, isEditable: true),
            MacroEnvironment(context: .editor, fileName: "notes.md", isDirectory: true, hasSelection: true, isEditable: true),
            MacroEnvironment(context: .editor, fileName: "notes.md", isDirectory: false, hasSelection: false, isEditable: true),
            MacroEnvironment(context: .editor, fileName: "notes.md", isDirectory: false, hasSelection: true, isEditable: false),
            MacroEnvironment(context: .editor)
        ] { #expect(try !conditions.matches(environment)) }
        #expect(try MacroConditions(selection: .absent).matches(MacroEnvironment(context: .panel, hasSelection: false)))
        #expect(try !MacroConditions(selection: .absent).matches(MacroEnvironment(context: .panel)))
        #expect(throws: (any Error).self) { try MacroConditions(fileMask: "[").validate() }
        #expect(throws: MacroError.invalidConfiguration) { try MacroConditions(fileMask: "a\0b").validate() }
    }

    @Test func conditionalPlaybackPreflightsBeforeSideEffectsAndDoesNotRetestOwnSelectionChanges() async throws {
        let registry = CommandRegistry()
        var selected = false, count = 0
        try registry.register(id: "panel.toggle", title: "Toggle", contexts: [.panel]) { count += 1; selected.toggle() }
        let controller = MacroController(registry: registry, environmentProvider: {
            MacroEnvironment(context: .panel, fileName: "a.txt", isDirectory: false, hasSelection: selected)
        }) { .panel }
        var macro = CommandMacro(name: "Conditional", steps: [MacroStep(commandID: "panel.toggle", context: .panel, repeatCount: 3)],
                                 conditions: MacroConditions(fileMask: "*.txt", entryKind: .file, selection: .present))
        do { try await controller.play(macro); Issue.record("Unmet selection must reject playback") }
        catch { #expect(error as? MacroError == .conditionsNotMet) }
        #expect(count == 0)
        selected = true
        try await controller.play(macro)
        #expect(count == 3)
        // Unavailable state does not satisfy an imported condition.
        let unknown = MacroController(registry: registry) { .panel }
        macro.conditions = MacroConditions(selection: .absent)
        do { try await unknown.play(macro); Issue.record("Missing state must reject conditional playback") }
        catch { #expect(error as? MacroError == .conditionsNotMet) }
        #expect(count == 3)
    }

    @Test func activationIsRecheckedAfterYieldBeforeFirstCommand() async throws {
        let registry = CommandRegistry()
        var selected = true, count = 0
        try registry.register(id: "panel.next", title: "Next", contexts: [.panel]) { count += 1 }
        var snapshots = 0
        let controller = MacroController(registry: registry, environmentProvider: {
            snapshots += 1
            defer { selected = false }
            return MacroEnvironment(context: .panel, hasSelection: selected)
        }) { .panel }
        let macro = CommandMacro(name: "Race", steps: [MacroStep(commandID: "panel.next", context: .panel)], conditions: MacroConditions(selection: .present))
        do { try await controller.play(macro); Issue.record("Changed activation must reject playback") }
        catch { #expect(error as? MacroError == .conditionsNotMet) }
        #expect(count == 0)
        #expect(snapshots == 2)
    }

    @Test func repeatBudgetsPreflightAndCancellationApplyToEachRepetition() async throws {
        let registry = CommandRegistry()
        let controller = MacroController(registry: registry) { .panel }
        var count = 0
        try registry.register(id: "panel.next", title: "Next", contexts: [.panel]) { count += 1; controller.stop() }
        let step = MacroStep(commandID: "panel.next", context: .panel, repeatCount: 256)
        do { try await controller.play(CommandMacro(name: "Repeat", steps: [step])); Issue.record("Expected repeat cancellation") }
        catch { #expect(error as? MacroError == .cancelled) }
        #expect(count == 1)
        for steps in [[step, step], [MacroStep(commandID: "panel.next", context: .panel, repeatCount: Int.max)],
                      [MacroStep(commandID: "panel.next", context: .panel, repeatCount: 0)]] {
            #expect(throws: MacroError.invalidConfiguration) { try MacroConfiguration(macros: [CommandMacro(name: "Budget", steps: steps)]).validate() }
        }
    }

    @Test func extendedMacrosRoundTripAndLegacyV1KeepsSingleExecution() throws {
        let original = MacroConfiguration(macros: [CommandMacro(name: "Old", steps: [MacroStep(commandID: "panel.next", context: .panel)])])
        var object = try #require(JSONSerialization.jsonObject(with: MacroPersistence.encode(original)) as? [String: Any])
        var macros = try #require(object["macros"] as? [[String: Any]])
        var steps = try #require(macros[0]["steps"] as? [[String: Any]])
        steps[0].removeValue(forKey: "repeatCount"); macros[0]["steps"] = steps
        macros[0].removeValue(forKey: "conditions"); object["macros"] = macros
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let old = try MacroPersistence.decode(legacy)
        #expect(old.macros[0].steps[0].repeatCount == 1)
        #expect(old.macros[0].conditions == nil)
        var extended = old
        extended.macros[0].conditions = MacroConditions(fileMask: "*.md", selection: .absent)
        extended.macros[0].steps[0].repeatCount = 4
        #expect(try MacroPersistence.decode(MacroPersistence.encode(extended)) == extended)
    }

}
