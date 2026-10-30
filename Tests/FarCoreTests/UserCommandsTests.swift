import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
final class UserCommandsTests {
    private let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FarCommands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    private func encoded(_ configuration: UserCommandConfiguration) throws -> Data { try JSONEncoder().encode(configuration) }
    private var context: UserCommandContext {
        UserCommandContext(currentFile: root.appendingPathComponent("O'Brien $(printf INJECTED); space\n.txt"),
                           markedFiles: [root.appendingPathComponent("one file"), root.appendingPathComponent("two'files")],
                           activeDirectory: root, passiveDirectory: root.appendingPathComponent("passive dir"))
    }

    @Test func placeholdersAreShellArgumentsAndCannotInjectSyntax() throws {
        let command = try UserCommandExpander.expand("printf '%s\\n' {name} {path} {marked} {active} {passive}", context: context)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]; process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let values = [context.currentFile!.lastPathComponent, context.currentFile!.path]
            + context.markedFiles.map(\.path) + [context.activeDirectory.path, context.passiveDirectory.path]
        #expect(String(data: data, encoding: .utf8) == values.joined(separator: "\n") + "\n")
    }

    @Test func unsupportedOrAmbiguousPlaceholdersFailExplicitly() throws {
        for template in ["echo {unknown}", "echo {path", "echo \"{path}\"", "echo '{path}'", "echo prefix{path}",
                         "echo {path}suffix", "echo \\{path}", "echo $(printf {path})", "echo `{path}`", "cat <<EOF {path}",
                         "# \"\nprintf \"{path}\"", "printf $'\\' {path} '"] {
            #expect(throws: (any Error).self) { try UserCommandExpander.expand(template, context: context) }
        }
        #expect(try UserCommandExpander.expand("printf literal", context: context) == "printf literal")
        let empty = UserCommandContext(currentFile: nil, markedFiles: [], activeDirectory: root, passiveDirectory: root)
        #expect(throws: (any Error).self) { try UserCommandExpander.expand("echo {name}", context: empty) }
        #expect(throws: (any Error).self) { try UserCommandExpander.expand("echo {marked}", context: empty) }
        #expect(throws: (any Error).self) { try UserCommandExpander.validate("echo\0bad") }
        #expect(throws: (any Error).self) { try UserCommandExpander.validate(String(repeating: "a", count: 16_385)) }
    }

    @Test func nestedMenusAndAssociationActionsRoundTrip() throws {
        let configuration = UserCommandConfiguration(menu: [UserMenuEntry(title: "Root", children: [UserMenuEntry(title: "Leaf", command: "ls -- {active}", key: "L")])],
            associations: [UserFileAssociation(title: "Texts", mask: "*.txt,*.md|secret*", execute: "file -- {path}", view: "cat -- {path}"),
                           UserFileAssociation(title: "Markdown editor", mask: "*.md", edit: "vi -- {path}")])
        let loaded = try UserCommandConfiguration.decode(encoded(configuration))
        #expect(loaded == configuration)
        #expect(try loaded.matchingAssociations(for: "README.MD", action: .view).map(\.title) == ["Texts"])
        #expect(try loaded.matchingAssociations(for: "secret.md", action: .execute).isEmpty)
        #expect(try loaded.matchingAssociations(for: "README.md", action: .edit).map(\.title) == ["Markdown editor"])
        #expect(try loaded.matchingAssociations(for: "README.txt", action: .edit).isEmpty)
        #expect(try UserCommandConfiguration.decode(Data(UserCommandStore.example.utf8)).menu.count == 2)
        #expect(try UserCommandConfiguration.decode(Data(#"{"version":1,"menu":[]}"#.utf8)).associations.isEmpty)
    }

    @Test func invalidStructureMasksKeysAndLimitsAreRejected() throws {
        let badConfigurations = [
            UserCommandConfiguration(version: 2),
            UserCommandConfiguration(menu: [UserMenuEntry(title: "", command: "true")]),
            UserCommandConfiguration(menu: [UserMenuEntry(title: "both", command: "true", children: [])]),
            UserCommandConfiguration(menu: [UserMenuEntry(title: "neither")]),
            UserCommandConfiguration(menu: [UserMenuEntry(title: "empty", children: [])]),
            UserCommandConfiguration(menu: [UserMenuEntry(title: "a", command: "true", key: "A"), UserMenuEntry(title: "b", command: "true", key: "a")]),
            UserCommandConfiguration(menu: [UserMenuEntry(title: "a", command: "true", key: "F1")]),
            UserCommandConfiguration(associations: [UserFileAssociation(title: "bad", mask: "[")]),
            UserCommandConfiguration(associations: [UserFileAssociation(title: "no commands", mask: "*")]),
            UserCommandConfiguration(menu: (0..<513).map { UserMenuEntry(title: "\($0)", command: "true") })
        ]
        for config in badConfigurations { #expect(throws: (any Error).self) { try UserCommandConfiguration.decode(encoded(config)) } }
        var entry = UserMenuEntry(title: "leaf", command: "true")
        for _ in 0..<8 { entry = UserMenuEntry(title: "parent", children: [entry]) }
        #expect(throws: (any Error).self) { try UserCommandConfiguration.decode(encoded(UserCommandConfiguration(menu: [entry]))) }
        for text in ["{", #"{"version":1,"menue":[]}"#, #"{"version":1,"menu":[{"title":"typo","commmand":"true"}]}"#,
                     String(repeating: "[", count: 25) + String(repeating: "]", count: 25), String(repeating: " ", count: 262_145)] {
            #expect(throws: (any Error).self) { try UserCommandConfiguration.decode(Data(text.utf8)) }
        }
    }

    @Test func localMenuOverridesGlobalOnlyOnExplicitReadAndKeepsProvenance() throws {
        let globalURL = root.appendingPathComponent("support/commands.json")
        let store = UserCommandStore(globalURL: globalURL)
        #expect(try store.loadGlobal().menu.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: globalURL.path))
        let global = UserCommandConfiguration(menu: [UserMenuEntry(title: "global", command: "true")])
        try store.saveGlobalText(String(data: encoded(global), encoding: .utf8)!)
        let initial = try store.loadMenu(in: root)
        #expect(initial.source == globalURL && !initial.isLocal && initial.entries == global.menu)
        let localURL = root.appendingPathComponent(UserCommandStore.localFilename)
        let marker = root.appendingPathComponent("must-not-run")
        let local = UserCommandConfiguration(menu: [UserMenuEntry(title: "local", command: "touch " + (try ShellCommand.quoteArgument(marker.path)))])
        try encoded(local).write(to: localURL)
        let loaded = try store.loadMenu(in: root)
        #expect(loaded.source == localURL && loaded.isLocal && loaded.entries == local.menu)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try Data("broken".utf8).write(to: localURL)
        #expect(throws: (any Error).self) { try store.loadMenu(in: root) }
        #expect(try store.loadGlobal().menu == global.menu)
        let attributes = try FileManager.default.attributesOfItem(atPath: globalURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func specialFilesSymlinksAndOversizedConfigAreRejectedWithoutBlocking() throws {
        let local = root.appendingPathComponent(UserCommandStore.localFilename)
        let store = UserCommandStore(globalURL: root.appendingPathComponent("global.json"))
        #expect(mkfifo(local.path, 0o600) == 0)
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: (any Error).self) { try store.loadMenu(in: root) }
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
        try FileManager.default.removeItem(at: local)
        let target = root.appendingPathComponent("target.json")
        try encoded(UserCommandConfiguration()).write(to: target)
        try FileManager.default.createSymbolicLink(at: local, withDestinationURL: target)
        #expect(throws: (any Error).self) { try store.loadMenu(in: root) }
        try FileManager.default.removeItem(at: local)
        try Data(repeating: 32, count: 262_145).write(to: local)
        #expect(throws: (any Error).self) { try store.loadMenu(in: root) }
    }

    @Test func failedValidationPreservesSavedConfiguration() throws {
        let store = UserCommandStore(globalURL: root.appendingPathComponent("commands.json"))
        try store.saveGlobalText(UserCommandStore.example)
        #expect(throws: (any Error).self) { try store.saveGlobalText("{}") }
        #expect(try store.loadGlobalText() == UserCommandStore.example)
    }
}
