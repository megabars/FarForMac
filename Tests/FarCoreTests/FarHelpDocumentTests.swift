import Foundation
import Testing
@testable import FarCore

@Suite struct FarHelpDocumentTests {
    @Test func headingsEscapesColorsLinksAndParagraphsMatchHelpNotation() throws {
        let document = try FarHelpDocument(#"""
        .Language=English,English
        .PluginContents=Demo HLF
        .Options CtrlColorChar=\
        .Options CtrlStartPosChar=^<wrap>
        @Alias=Second

        @Contents
        $^#Heading#
         • ^<wrap>First line ##hash## @@at ~~tilde \\slash
        continuation \1Fcolored\- normal
         ~#Go# ~~ next~@Alias@
         ~Other~@<nested\More.hlf>Deep@
        @-
         #fixed#  spaces
         next fixed
        @+
        @=*
        @Second
        $ #Second#
        """#)
        #expect(document.language == "English,English")
        #expect(document.title == "Demo HLF")
        let contents = try document.topic()
        #expect(contents.paragraphs.first?.kind == .heading(centered: true))
        #expect(contents.paragraphs.first?.plainText == "Heading")
        #expect(contents.paragraphs[1].hangingIndent == 3)
        #expect(contents.paragraphs[1].plainText == " • First line #hash# @at ~tilde \\slash continuation colored normal")
        #expect(contents.paragraphs[1].runs.contains { $0.text == "colored" && $0.consoleColor == 0x1F })
        #expect(contents.paragraphs.flatMap(\.runs).contains { $0.link == .file("nested/More.hlf", topic: "Deep") })
        #expect(contents.paragraphs.flatMap(\.runs).contains { $0.text == "Go" && $0.highlighted && $0.link == .topic("Alias") })
        #expect(contents.paragraphs.contains { $0.kind == .preformatted && $0.plainText == " fixed  spaces" })
        #expect(contents.paragraphs.contains { $0.kind == .rule("*") })
        #expect(try document.topic(named: "aLIas").name == "Second")
    }

    @Test func editorTopicNavigationUsesSourceLineAndErrorsDoNotChooseAnotherTopic() throws {
        let document = try FarHelpDocument(".Language=English\r\n.Header=ignored\r\n@a=b\r\n@b=a\r\n@Contents\r\nA\r\n@Details\r\nB")
        #expect(document.topic(atSourceLine: 0).name == "Contents")
        #expect(document.topic(atSourceLine: 5).name == "Contents")
        #expect(document.topic(atSourceLine: 6).name == "Details")
        #expect(throws: FarHelpError.missingTopic("Missing")) { try document.topic(named: "Missing") }
        #expect(throws: FarHelpError.cyclicAlias("a")) { try document.topic(named: "a") }
        #expect(throws: FarHelpError.invalidDocument) { try FarHelpDocument("Plain text\n@Topic") }
    }

    @Test func commandSyntaxAndUntrustedControlPayloadsAreBounded() throws {
        #expect(try FarHelpInvocation(arguments: "") == .usage)
        #expect(try FarHelpInvocation(arguments: "@Editor") == .hostTopic("Editor"))
        #expect(try FarHelpInvocation(arguments: "Viewer") == .nameOrTopic("Viewer"))
        #expect(try FarHelpInvocation(arguments: #""folder/demo file.hlf" @Second"#) == .file("folder/demo file.hlf", topic: "Second"))
        let guid = try #require(UUID(uuidString: "1AF0754D-5020-49CB-9474-1F82691C84C1"))
        #expect(try FarHelpInvocation(arguments: "{\(guid.uuidString)} Contents") == .plugin(guid, topic: "Contents"))
        #expect(throws: FarHelpError.invalidCommand) { try FarHelpInvocation(arguments: "bad\u{0}path") }
        #expect(throws: FarHelpError.invalidCommand) { try FarHelpInvocation(arguments: "\"unterminated.hlf") }
        let document = try FarHelpDocument(".Language=English\n@Contents\n~Example~@https://example.invalid@ \u{1b}text")
        let runs = try document.topic().paragraphs.flatMap(\.runs)
        #expect(runs.first?.link == .unsupported("https://example.invalid"))
        #expect(runs.map(\.text).joined() == "Example text")
    }
}
