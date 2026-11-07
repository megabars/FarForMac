import Foundation
import Testing
@testable import FarCore

@Suite
struct InternalCommandTests {
    @Test func dispatchesEnvironmentConditionsAndPrefixes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FarInternal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("it's here.txt"))
        var state = InternalCommandState(baseEnvironment: ["Path": "/bin", "FIXTURE": directory.path])
        let source = "@IF EXIST 'it'\\''s here.txt' if not exist missing if defined path @printf '%s' ready"
        let dispatch = try state.dispatch(source, currentDirectory: directory)
        #expect(dispatch.action == .shell("printf '%s' ready"))
        #expect(!dispatch.echo)
        #expect(try state.dispatch("if exist *.txt title ready", currentDirectory: directory).action == .title("ready"))
        #expect(try state.dispatch("if not defined PATH printf unwanted", currentDirectory: directory).action == .skip)
        #expect(try state.dispatch("if [ -f foo ]; then echo ok; fi", currentDirectory: directory).action == .shell("if [ -f foo ]; then echo ok; fi"))
        #expect(try state.dispatch("set \"VALUE=found %PATH%\"", currentDirectory: directory).action == .skip)
        #expect(state.environmentOverrides["VALUE"] == "found /bin")
        #expect(try state.dispatch("set val", currentDirectory: directory).action == .output("VALUE=found /bin\n"))
        #expect(try state.dispatch("set PATH=", currentDirectory: directory).action == .skip)
        #expect(state.environmentRemovals.contains("Path"))
        #expect(try state.dispatch("if defined Path far:about", currentDirectory: directory).action == .skip)
        #expect(try state.dispatch("far:regex", currentDirectory: directory).action == .far(.regex))
        #expect(try state.dispatch("far:error 0xFF", currentDirectory: directory).action == .far(.error(255)))
        #expect(try state.dispatch("lua: print(1)", currentDirectory: directory).action == .plugin(prefix: "lua", arguments: " print(1)"))
        #expect(try state.dispatch("cls", currentDirectory: directory).action == .clearScreen)
        #expect(try state.dispatch("title", currentDirectory: directory).action == .title(nil))
        #expect(try state.dispatch("exit 3", currentDirectory: directory).action == .exit(3))
    }

    @Test func directoryStackCommitsOnlyAfterPushNavigationAndPopConsumesTop() throws {
        let root = URL(fileURLWithPath: "/somewhere", isDirectory: true)
        var state = InternalCommandState(baseEnvironment: ["DEST": "/tmp"])
        let child = root.appendingPathComponent("child").standardizedFileURL
        let destination = try state.dispatch("PUSHD child", currentDirectory: root).action
        guard case .directory(let url, let close, let change?) = destination else {
            Issue.record("pushd did not request navigation"); return
        }
        #expect(url.path == child.path)
        #expect(close)
        #expect(state.directoryStack.isEmpty)
        state.commit(change)
        #expect(state.directoryStack == [root])
        #expect(state.environmentValue("FARDIRSTACK") == root.path)
        #expect(try state.dispatch("popd", currentDirectory: child).action == .directory(root, closeProvider: true, stack: nil))
        #expect(state.directoryStack.isEmpty)
        #expect(state.environmentValue("FARDIRSTACK") == nil)
        #expect(try state.dispatch("cd %DEST%", currentDirectory: root).action == .directory(URL(fileURLWithPath: "/tmp").standardizedFileURL, closeProvider: false, stack: nil))
        #expect(try state.dispatch("chdir /D '/some path'", currentDirectory: root).action == .directory(URL(fileURLWithPath: "/some path"), closeProvider: true, stack: nil))
        #expect(try state.dispatch("cd / && pwd", currentDirectory: root).action == .shell("cd / && pwd"))
    }

    @Test func associationsFilterConditionsAndSubstituteSafeRegexCaptures() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FarAssociation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a';&.txt")
        try Data().write(to: file)
        let context = UserCommandContext(currentFile: file, markedFiles: [], activeDirectory: dir, passiveDirectory: dir)
        let filtered = UserFileAssociation(title: "False", mask: "*.txt", execute: "if not exist !.! echo wrong", farSyntax: true)
        let native = UserFileAssociation(title: "%RegexGroup{stem name}", mask: #"/^(?{stem name}.+)\.(txt)$/"#,
            execute: "if exist !.! printf '%s' %RegexGroup{stem name} %RegexGroup2", farSyntax: true)
        let legacy = UserFileAssociation(title: "Legacy", mask: #"/^(.+)\.txt$/"#, execute: "printf '%s' %RegexGroup1")
        let commands = InternalCommandState(baseEnvironment: [:])
        let config = UserCommandConfiguration(associations: [filtered, native, legacy])
        let restored = try UserCommandConfiguration.decode(JSONEncoder().encode(config))
        let matches = try restored.resolveAssociations(for: file.lastPathComponent, action: .execute, context: context, commands: commands)
        #expect(matches.hasMatchingAction)
        #expect(matches.candidates.map(\.title) == ["a';&", "Legacy"])
        let prepared = try UserCommandExpander.prepare(matches.candidates[0].template, context: context)
        var state = commands
        let dispatch = try state.dispatch(prepared.command, currentDirectory: dir)
        #expect(dispatch.action == .shell("printf '%s' 'a'\\'';&' 'txt'"))
        let hidden = try UserCommandConfiguration(associations: [filtered]).resolveAssociations(for: file.lastPathComponent, action: .execute, context: context, commands: commands)
        #expect(hidden.hasMatchingAction && hidden.candidates.isEmpty)
    }

    @Test func silentManagedOutputDropsOnlyEchoAndKeepsSplitProtocolFrames() throws {
        let integration = try PersistentShellIntegration()
        integration.suppressNextCommandEcho()
        let prefix = "\u{1b}]777;farformac;\(integration.token);"
        #expect(integration.filterCommandEcho(Data("typed command\r\n\(prefix)bu".utf8)).isEmpty)
        #expect(integration.filterCommandEcho(Data("sy\u{7}output".utf8)) == Data("\r\noutput".utf8))
        #expect(integration.filterCommandEcho(Data("more".utf8)) == Data("more".utf8))
        integration.suppressNextCommandEcho()
        let ready = prefix + "ready;1;Lw==\u{7}"
        #expect(integration.filterCommandEcho(Data(("echo and parse failure" + ready).utf8)) == Data(("\r\n" + ready).utf8))
        #expect(try PersistentShellIntegration.submission("echo secret", echo: false) == " echo secret\n")
    }
}
