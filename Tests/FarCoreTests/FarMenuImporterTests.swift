import Foundation
import Testing
@testable import FarCore

@Suite
struct FarMenuImporterTests {
    @Test func importsNestedMenusSeparatorsFunctionKeysAndPOSIXCommands() throws {
        let source = """
        ; explicit import
        F3: Inspect
          file "!.!"
        --:
        D: Directories
        {
        1: Active
          ls !\u{5c}
        2: Passive
          ls !#!\u{5c}
        }
        """
        let result = try FarMenuImporter.parse(Data(source.utf8))
        #expect(result.menu.count == 3)
        #expect(result.menu[0].key == "F3" && result.menu[0].command == "file {name}")
        #expect(result.menu[1].separator == true)
        #expect(result.menu[2].children?.map(\.command) == ["ls {active}", "ls {passive}"])
        #expect(!result.warnings.isEmpty)
    }

    @Test func translatesSafeMetasymbolArgumentsAndPanelSwitches() throws {
        let source = "printf '%s' ! !` !.! !&Q !# !.! !& !^ !\\!.! !!"
        #expect(try FarMenuImporter.convertCommand(source) == "printf '%s' {stem} {extension} {name} {selectedNames}  {passiveName} {passiveSelectedNames}  {path} !")
        #expect(try FarMenuImporter.convertCommand("diff \"!\\!.!\" \"!#!\\!.!\"") == "diff {path} {passivePath}")
        #expect(try FarMenuImporter.convertCommand("echo !#!.! !& !^!.! !&") == "echo {passiveName} {passiveSelectedNames} {name} {selectedNames}")
    }

    @Test func translatesInteractiveAndListParametersWithExplicitLimits() throws {
        #expect(try FarMenuImporter.convertCommand("grep !?Search?initial! !.!") == "grep {input:Search|initial} {name}")
        #expect(try FarMenuImporter.convertCommand("tool !@! !@UF! !#!@US!") == "tool {listNames} {list} {passiveListNames}")
        #expect(try FarMenuImporter.convertCommand("tool \"!@UF!\"") == "tool {list}")
        for command in ["tool !@Q!", "tool !$!", "tool !@W!", "echo !~", "echo !&q", "echo !&~", "echo !:", "echo !?!", "echo ![!.!", "echo !=\\", "echo !?bad", "echo !?$History$Search?!", "echo !?Find (!.!)?!", "echo !-!", "echo !+!", "echo !`~"] {
            #expect(throws: (any Error).self) { try FarMenuImporter.convertCommand(command) }
        }
    }

    @Test func rejectsAmbiguousConcatenationAndWindowsConditionsRatherThanChangingMeaning() throws {
        for command in ["echo prefix!.!", "echo \"prefix!.!\"", "echo \"!\\!.!\"suffix", "@echo !.!", "echo %UserVar0", "echo %TEMP%", "echo !?A|B?!"] {
            #expect(throws: (any Error).self) { try FarMenuImporter.convertCommand(command) }
        }
        #expect(try FarMenuImporter.convertCommand("printf '%s\\n' literal") == "printf '%s\\n' literal")
    }

    @Test func supportsUTF8BOMAndUTF16BOMWithoutGuessingOEM() throws {
        let source = "F2: Кириллица\n  echo !.!\n"
        let utf8 = Data([0xef, 0xbb, 0xbf]) + Data(source.utf8)
        let le = Data([0xff, 0xfe]) + source.data(using: .utf16LittleEndian)!
        let be = Data([0xfe, 0xff]) + source.data(using: .utf16BigEndian)!
        for data in [utf8, le, be] {
            #expect(try FarMenuImporter.parse(data).menu[0].title == "Кириллица")
        }
        #expect(throws: (any Error).self) { try FarMenuImporter.parse(Data([0xff, 0xfe, 0xff])) }
        #expect(throws: (any Error).self) { try FarMenuImporter.parse(Data([0xcf, 0xf0, 0xe8, 0xe2, 0xe5, 0xf2])) }
    }

    @Test func malformedMenusAndMultipleCommandLinesFailAsWholeImport() throws {
        for source in ["", "}", "{", "A: Empty", "A: Commands\n  echo first\n  echo second", "  echo orphan", "A: Root\n{\nB: Leaf\n  true", "A: First\n  true\na: Duplicate\n  true", "F25: Invalid\n  true", "A: bad\n  true\n{\nB: Leaf\n  true\n}", "A: Bad\n  echo\0bad"] {
            #expect(throws: (any Error).self) { try FarMenuImporter.parse(Data(source.utf8)) }
        }
        let many = (0..<513).map { ": Entry\($0)\n  true" }.joined(separator: "\n")
        #expect(throws: (any Error).self) { try FarMenuImporter.parse(Data(many.utf8)) }
        let deep = (0..<9).map { "A: Level\($0)\n{" }.joined(separator: "\n") + "\nZ: Leaf\n  true\n" + String(repeating: "}\n", count: 9)
        #expect(throws: (any Error).self) { try FarMenuImporter.parse(Data(deep.utf8)) }
        #expect(throws: (any Error).self) { try FarMenuImporter.parse(Data(repeating: 32, count: 262_145)) }
    }

    @Test func importsEmptySubmenuAndKeepsFollowingCommandsAtTheSameLevel() throws {
        let source = "A: Root\n{\n}\nB: Next\n  true\n"
        let imported = try FarMenuImporter.parse(Data(source.utf8))
        #expect(imported.menu == [
            UserMenuEntry(title: "Root", children: [], key: "A"),
            UserMenuEntry(title: "Next", command: "true", key: "B")
        ])
    }

    @Test func importOnlyReadsFileAndNeverExecutesItsCommandsOrOverwritesConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FarMenuImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let global = directory.appendingPathComponent("commands.json"), menu = directory.appendingPathComponent("FarMenu.ini"), marker = directory.appendingPathComponent("must-not-exist")
        let store = UserCommandStore(globalURL: global)
        try store.saveGlobalText(UserCommandStore.example)
        try Data(("A: Never run\n  touch " + ShellCommand.quoteArgument(marker.path) + "\n").utf8).write(to: menu)
        #expect(try store.importFarMenu(at: menu).menu.count == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try store.loadGlobalText() == UserCommandStore.example)
        try FileManager.default.removeItem(at: menu)
        try FileManager.default.createSymbolicLink(at: menu, withDestinationURL: global)
        #expect(throws: (any Error).self) { try store.importFarMenu(at: menu) }
    }

    @Test func nativeFormatPreservesCommandXLinesPunctuationAndNestedMenu() throws {
        let source = """
        F4: Inspect !.!
          REM fixture
          printf '%s' !.!
          :: comment
          false
          pwd
        --: Divider
        }: Menu
        {
        :: Colon hotkey
          true
        }
        """
        let result = try FarMenuImporter.parseNative(Data(source.utf8))
        #expect(result.menu.map(\.key) == ["F4", nil, "}"])
        #expect(result.menu[1].separator == true && result.menu[1].title == "Divider")
        #expect(result.menu[2].children?.first?.key == ":")
        let block = try #require(result.menu[0].command)
        #expect(FarMenuImporter.commandLines(in: block) == ["printf '%s' !.!", "false", "pwd"])
        let config = UserCommandConfiguration(menu: result.menu)
        #expect(try UserCommandConfiguration.decode(JSONEncoder().encode(config)) == config)
    }

    @Test func nativeSourcePrecedenceCyclesAndSavesTheOriginalFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FarMenuNative-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("parent/gap/local", isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let installation = root.appendingPathComponent("install", isDirectory: true)
        let profile = root.appendingPathComponent("profile", isDirectory: true)
        for dir in [local, installation, profile] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let store = UserCommandStore(globalURL: profile.appendingPathComponent("commands.json"), installationMenuDirectory: installation)
        try store.saveGlobalText(UserCommandStore.example)
        let localJSON = local.appendingPathComponent(UserCommandStore.localFilename)
        try Data(UserCommandStore.example.utf8).write(to: localJSON)
        for (directory, title) in [(local, "Local"), (parent, "Parent"), (installation, "Installation"), (profile, "Profile")] {
            let encoded = try #require("F2: \(title)\r\n  true\r\n".data(using: .utf16LittleEndian))
            try (Data([0xff, 0xfe]) + encoded).write(to: directory.appendingPathComponent("FarMenu.ini"))
        }
        let initial = try store.loadMenu(in: local)
        #expect(initial.location == .local && initial.isFarMenu && initial.entries[0].title == "Local")
        let fromParent = try store.loadParentMenu(of: initial)
        #expect(fromParent.source == parent.appendingPathComponent("FarMenu.ini") && fromParent.entries[0].title == "Parent")
        let installed = try store.nextMenu(after: fromParent, in: local)
        #expect(installed.location == .installation)
        let user = try store.nextMenu(after: installed, in: local)
        #expect(user.location == .profile && user.entries[0].title == "Profile")
        #expect(try store.nextMenu(after: user, in: local).source == initial.source)
        #expect(try store.loadMenu(in: root).source == installed.source)

        var modified = initial.entries
        modified[0].title = "Обновлено"
        let saved = try store.saveMenu(modified, replacing: initial)
        #expect(try Data(contentsOf: saved.source).starts(with: [0xff, 0xfe]))
        #expect(try store.farMenuText(saved) == "F2: Обновлено\r\n     true\r\n")
        #expect(try String(contentsOf: localJSON, encoding: .utf8) == UserCommandStore.example)
        #expect(throws: (any Error).self) { try store.saveMenu([], replacing: initial) }
        #expect(try store.saveMenu([], replacing: saved).entries.isEmpty)
        #expect(try store.loadMenu(in: local).entries.isEmpty)
    }

    @Test func nativeMetasymbolsUsePhysicalPanelsAndQuoteAsLiteralArguments() throws {
        let right = URL(fileURLWithPath: "/right", isDirectory: true)
        let left = URL(fileURLWithPath: "/left", isDirectory: true)
        let active = right.appendingPathComponent("A'; $(danger).txt")
        let passive = left.appendingPathComponent("B.txt")
        let ctx = UserCommandContext(currentFile: active, markedFiles: [], activeDirectory: right, passiveDirectory: left,
            passiveCurrentFile: passive, activePanelIsLeft: false)
        let source = #"printf '%s' "![!.!" "!]!.!" "!#!\!^!.!" !!"#
        let template = try FarMenuMetasymbols.command(source, context: ctx)
        #expect(template == "printf '%s' {passiveName} {name} {farPathPA} !")
        #expect(try UserCommandExpander.expand(template, context: ctx) == "printf '%s' 'B.txt' 'A'\\''; $(danger).txt' '/left/A'\\''; $(danger).txt' !")
        #expect(FarMenuMetasymbols.title("&Inspect ![!.! / !]!.! && !!", context: ctx) == "Inspect B.txt / A'; $(danger).txt & !")
        let composite = try FarMenuMetasymbols.command("printf '%s' prefix!.!.bak", context: ctx)
        #expect(try UserCommandExpander.expand(composite, context: ctx) == "printf '%s' prefix'A'\\''; $(danger).txt'.bak")
        for unsupported in ["echo $!.!", "echo !.!$suffix", "echo prefix!&", "echo !~", "echo !$!", "echo !@A!", "echo !&q"] {
            #expect(throws: (any Error).self) { try FarMenuMetasymbols.command(unsupported, context: ctx) }
        }
    }

    @Test func nativePromptReferencesAndNestedTitleUseIndependentFields() throws {
        let dir = URL(fileURLWithPath: "/folder", isDirectory: true)
        let context = UserCommandContext(currentFile: dir.appendingPathComponent("A&B.txt"), markedFiles: [], activeDirectory: dir, passiveDirectory: dir)
        let template = try FarMenuMetasymbols.command(#"printf '%s' !?$Search$Find in (!.!):?(!)! !?$$Find in (!.!):?(!)! %UserVar1 %Search %UserVar2"#, context: context)
        let inputs = try UserCommandExpander.inputs(in: template)
        #expect(inputs.count == 2)
        #expect(inputs.map(\.title) == ["Find in A&B.txt:", "Find in A&B.txt:"])
        #expect(inputs.map(\.defaultValue) == ["A&B", "A&B"])
        #expect(inputs.map(\.historyName) == ["Search", nil])
        #expect(inputs.map(\.variableName) == ["Search", nil])
        let prepared = try UserCommandExpander.prepare(template, context: context,
            inputValues: [inputs[0].identifier: "a;", inputs[1].identifier: "b|"])
        #expect(prepared.isEphemeral)
        #expect(prepared.command == "printf '%s' 'a;' 'b|' 'a;' 'a;' 'b|'")
        let next = try FarMenuMetasymbols.command("printf '%s' %search", context: context, variables: ["Search": "a;"], variablesArePrivate: true)
        let reused = try UserCommandExpander.prepare(next, context: context)
        #expect(reused.command == "printf '%s' 'a;'" && reused.isEphemeral)
        #expect(FarMenuMetasymbols.title("Inspect !.!", context: context) == "Inspect A&B.txt")
    }

    @Test func nativeListModifiersAndPromptsProducePrivateLiteralValues() throws {
        let directory = URL(fileURLWithPath: "/folder", isDirectory: true)
        let file = directory.appendingPathComponent("Имя \"quoted\".txt")
        let ctx = UserCommandContext(currentFile: file, markedFiles: [], activeDirectory: directory, passiveDirectory: directory)
        let template = try FarMenuMetasymbols.command("tool !@FQW! !@U! !?Search?initial!", context: ctx)
        let input = try #require(UserCommandExpander.inputs(in: template).first)
        #expect(input.title == "Search" && input.defaultValue == "initial")
        let prepared = try UserCommandExpander.prepare(template, context: ctx, inputValues: [input.identifier: "; literal"])
        let wide = try #require(prepared.listFiles["farListAFQW"])
        let plain = try #require(prepared.listFiles["farListA"])
        let wideData = try Data(contentsOf: wide)
        #expect(wideData.starts(with: [0xff, 0xfe]))
        #expect(String(data: wideData.dropFirst(2), encoding: .utf16LittleEndian) == "\"/folder/Имя \"\"quoted\"\".txt\"\n")
        #expect(try String(contentsOf: plain, encoding: .utf8) == "Имя \"quoted\".txt\n")
        #expect(prepared.command.hasSuffix("'; literal'"))
        prepared.cleanup()
        #expect(!FileManager.default.fileExists(atPath: wide.path))
    }
}
