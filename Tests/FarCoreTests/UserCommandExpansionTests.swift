import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
final class UserCommandExpansionTests {
    private let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FarCommandParameters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    private func context(marked: [String] = []) -> UserCommandContext {
        UserCommandContext(currentFile: root.appendingPathComponent("O'Brien; literal $(bad).tar.gz"), markedFiles: marked.map { root.appendingPathComponent($0) },
                           activeDirectory: root, passiveDirectory: root.appendingPathComponent("other directory"),
                           passiveCurrentFile: root.appendingPathComponent("other directory/another ф.md"),
                           passiveMarkedFiles: [root.appendingPathComponent("other directory/marked first"), root.appendingPathComponent("other directory/marked 'second'")])
    }
    private func output(_ command: String) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return data
    }

    @Test func inputsAreUniqueOrderedAndRequireExplicitValues() throws {
        let template = "printf '%s\\n' {input:Search|literal text} {input:Other} {input:Search|literal text}"
        let inputs = try UserCommandExpander.inputs(in: template)
        #expect(inputs.map(\.title) == ["Search", "Other"])
        #expect(inputs.map(\.defaultValue) == ["literal text", ""])
        #expect(throws: (any Error).self) { try UserCommandExpander.expand(template, context: context()) }
        #expect(try UserCommandExpander.inputs(in: "true").isEmpty)
    }

    @Test func interactiveValuesRemainLiteralShellArgumentsIncludingEmptyAndNewline() throws {
        let template = "printf '%s\\n' {input:Search|default} {input:Empty}"
        let value = "O'Brien; $(printf INJECTED) `bad` \"ф\"\nnext"
        let prepared = try UserCommandExpander.prepare(template, context: context(), inputValues: ["input:Search|default": value, "input:Empty": ""])
        #expect(prepared.isEphemeral && prepared.listFiles.isEmpty)
        #expect(try output(prepared.command) == Data((value + "\n\n").utf8))
    }

    @Test func malformedInteractiveParametersAndLimitsFailBeforeExecution() throws {
        for template in ["echo {input:}", "echo {input: |value}", "echo {input:A\nB}", "echo {input:A|x{y}", "echo \"{input:A}\"",
                         (0..<17).map { "{input:field\($0)}" }.joined(separator: " ")] {
            #expect(throws: (any Error).self) { try UserCommandExpander.validate(template) }
        }
        for value in ["a\0b", String(repeating: "x", count: 65_537)] {
            #expect(throws: (any Error).self) { try UserCommandExpander.expand("echo {input:A}", context: context(), inputValues: ["input:A": value]) }
        }
    }

    @Test func shellCommentTemplatesRejectNewlinePayloadsBeforeAnyShellExecution() throws {
        let marker = root.appendingPathComponent("comment-marker")
        let payload = "x\nprintf harmless > " + (try ShellCommand.quoteArgument(marker.path)) + "; #"
        let current = UserCommandContext(currentFile: root.appendingPathComponent(payload), markedFiles: [], activeDirectory: root, passiveDirectory: root)
        for template in ["printf safe # {input:A}", "printf safe;# {input:A}", "printf safe |# {input:A}", "# {path}", "printf safe # {path}", "printf '%s' {input:A} # comment"] {
            #expect(throws: (any Error).self) { try UserCommandExpander.validate(template) }
            #expect(throws: (any Error).self) { try UserCommandExpander.prepare(template, context: current, inputValues: ["input:A": payload]) }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let safe = try UserCommandExpander.expand("printf '%s' {input:A} '#' literal#word", context: current, inputValues: ["input:A": payload])
        _ = try output(safe)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try UserCommandExpander.expand("printf literal # harmless", context: current) == "printf literal # harmless")
    }

    @Test func filenamePartsAndPassivePanelUseTheirOwnFileAndMarks() throws {
        let ctx = context()
        let result = try UserCommandExpander.expand("printf '%s\\n' {stem} {extension} {passiveName} {passivePath} {passiveStem} {passiveExtension} {passiveMarked}", context: ctx)
        let expected = ["O'Brien; literal $(bad).tar", "gz", "another ф.md", ctx.passiveCurrentFile!.path, "another ф", "md"] + ctx.passiveMarkedFiles.map(\.path)
        #expect(try output(result) == Data((expected.joined(separator: "\n") + "\n").utf8))
        let empty = UserCommandContext(currentFile: nil, markedFiles: [], activeDirectory: root, passiveDirectory: root)
        #expect(throws: (any Error).self) { try UserCommandExpander.expand("echo {passiveName}", context: empty) }
        #expect(throws: (any Error).self) { try UserCommandExpander.expand("echo {passiveMarked}", context: empty) }
    }

    @Test func listFilesContainMarkedPathsAndNamesInOrderWithPrivatePermissions() throws {
        let ctx = context(marked: ["one file", "two'files", "Файл"])
        let prepared = try UserCommandExpander.prepare("cat {list} {listNames} {passiveList} {passiveListNames}", context: ctx)
        #expect(prepared.listFiles.count == 4 && prepared.isEphemeral)
        let expected: [String: [String]] = ["list": ctx.markedFiles.map(\.path), "listNames": ctx.markedFiles.map(\.lastPathComponent),
                                           "passiveList": ctx.passiveMarkedFiles.map(\.path), "passiveListNames": ctx.passiveMarkedFiles.map(\.lastPathComponent)]
        for (name, url) in prepared.listFiles {
            #expect(try String(contentsOf: url, encoding: .utf8) == expected[name]!.joined(separator: "\n") + "\n")
            #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        let urls = Array(prepared.listFiles.values)
        prepared.cleanup(); prepared.cleanup()
        #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func listFallsBackToCurrentWhileMarkedStillRequiresRealMarks() throws {
        let ctx = context()
        let prepared = try UserCommandExpander.prepare("cat {list} {list}", context: ctx)
        #expect(prepared.listFiles.count == 1)
        #expect(try output(prepared.command) == Data((ctx.currentFile!.path + "\n" + ctx.currentFile!.path + "\n").utf8))
        #expect(throws: (any Error).self) { try UserCommandExpander.expand("echo {marked}", context: ctx) }
        let empty = UserCommandContext(currentFile: nil, markedFiles: [], activeDirectory: root, passiveDirectory: root)
        #expect(throws: (any Error).self) { try UserCommandExpander.prepare("cat {list}", context: empty) }
    }

    @Test func importedSelectedNamesUseMarksOrCurrentFilenameOnEachPanel() throws {
        let ctx = context(marked: ["first space", "second'quote"])
        let command = try UserCommandExpander.expand("printf '%s\\n' {selectedNames} {passiveSelectedNames}", context: ctx)
        let names = (ctx.markedFiles + ctx.passiveMarkedFiles).map(\.lastPathComponent)
        #expect(try output(command) == Data((names.joined(separator: "\n") + "\n").utf8))
        #expect(try output(UserCommandExpander.expand("printf '%s' {selectedNames}", context: context())) == Data(context().currentFile!.lastPathComponent.utf8))
    }

    @Test func nulListsPreserveNewlinesAndCanBeReadByRealPrograms() throws {
        let ctx = context(marked: ["one\nsecond", "quote'\rthird"])
        #expect(throws: (any Error).self) { try UserCommandExpander.prepare("cat {list}", context: ctx) }
        let prepared = try UserCommandExpander.prepare("cat {list0} {listNames0}", context: ctx)
        let expected = (ctx.markedFiles.map(\.path) + ctx.markedFiles.map(\.lastPathComponent)).map { Data(($0 + "\0").utf8) }.reduce(Data(), +)
        #expect(try output(prepared.command) == expected)
    }

    @Test func preparedResourcesAreRemovedOnReleaseAndAbsentWithoutLists() throws {
        var prepared: PreparedUserCommand? = try UserCommandExpander.prepare("cat {list0}", context: context())
        let url = prepared!.listFiles["list0"]!
        #expect(FileManager.default.fileExists(atPath: url.path))
        prepared = nil
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        let simple = try UserCommandExpander.prepare("printf '%s' {name}", context: context())
        #expect(simple.listFiles.isEmpty && !simple.isEphemeral)
        #expect(throws: (any Error).self) { try UserCommandExpander.expand("cat {list}", context: context()) }
    }

    @Test func eachPreparedCommandOwnsSeparateFilesAndBoundsListBytes() throws {
        let first = try UserCommandExpander.prepare("cat {list}", context: context())
        let second = try UserCommandExpander.prepare("cat {list}", context: context())
        #expect(first.listFiles["list"] != second.listFiles["list"])
        first.cleanup()
        #expect(FileManager.default.fileExists(atPath: second.listFiles["list"]!.path))
        let large = context(marked: Array(repeating: String(repeating: "x", count: 9000), count: 1000))
        #expect(throws: (any Error).self) { try UserCommandExpander.prepare("cat {list}", context: large) }
    }

    @Test func alternativeAssociationActionsAreIndependentAndOldJSONStillLoads() throws {
        let configuration = UserCommandConfiguration(associations: [UserFileAssociation(title: "Alt only", mask: "*.md", alternateExecute: "file {path}", alternateView: "cat {path}", alternateEdit: "vi {path}")])
        let loaded = try UserCommandConfiguration.decode(JSONEncoder().encode(configuration))
        #expect(loaded == configuration)
        #expect(try loaded.matchingAssociations(for: "Файл.MD", action: .execute).isEmpty)
        for action in [UserCommandAction.alternateExecute, .alternateView, .alternateEdit] {
            #expect(try loaded.matchingAssociations(for: "Файл.MD", action: action).count == 1)
        }
        let old = try UserCommandConfiguration.decode(Data(#"{"version":1,"menu":[{"title":"old","command":"true"}],"associations":[{"title":"old","mask":"*","execute":"true"}]}"#.utf8))
        #expect(old.menu[0].separator == nil && old.associations[0].alternateView == nil)
    }

    @Test func separatorsAndFunctionHotkeysValidateAndRoundTrip() throws {
        let configuration = UserCommandConfiguration(menu: [UserMenuEntry(title: "—", separator: true), UserMenuEntry(title: "Help", command: "true", key: "F24")])
        #expect(try UserCommandConfiguration.decode(JSONEncoder().encode(configuration)) == configuration)
        for entries in [[UserMenuEntry(title: "bad", command: "true", separator: true)],
                        [UserMenuEntry(title: "one", command: "true", key: "F3"), UserMenuEntry(title: "two", command: "true", key: "f3")],
                        [UserMenuEntry(title: "bad", command: "true", key: "F25")]] {
            #expect(throws: (any Error).self) { try UserCommandConfiguration(menu: entries).validate() }
        }
    }
}
