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
        for command in ["echo prefix!.!", "echo \"prefix!.!\"", "echo \"!\\!.!\"suffix", "if exist !.! type !.!", "@echo !.!", "echo %UserVar0", "echo %TEMP%", "echo !?A|B?!"] {
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
        for source in ["", "}", "{", "A: Empty", "A: Commands\n  echo first\n  echo second", "  echo orphan", "A: Root\n{\nB: Leaf\n  true", "A: Root\n{\n}", "A: First\n  true\na: Duplicate\n  true", "F25: Invalid\n  true", "A: bad\n  true\n{\nB: Leaf\n  true\n}", "A: Bad\n  echo\0bad"] {
            #expect(throws: (any Error).self) { try FarMenuImporter.parse(Data(source.utf8)) }
        }
        let many = (0..<513).map { ": Entry\($0)\n  true" }.joined(separator: "\n")
        #expect(throws: (any Error).self) { try FarMenuImporter.parse(Data(many.utf8)) }
        let deep = (0..<9).map { "A: Level\($0)\n{" }.joined(separator: "\n") + "\nZ: Leaf\n  true\n" + String(repeating: "}\n", count: 9)
        #expect(throws: (any Error).self) { try FarMenuImporter.parse(Data(deep.utf8)) }
        #expect(throws: (any Error).self) { try FarMenuImporter.parse(Data(repeating: 32, count: 262_145)) }
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
}
