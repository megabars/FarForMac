import Foundation
import Testing
@testable import FarCore

@Suite struct TerminalScreenTests {
    @Test func cursorEraseCRAndSplitUTF8AreInterpreted() {
        var screen = TerminalScreen(columns: 20, rows: 3)
        screen.append("progress 100%\rDone\u{1b}[K\r\n")
        let bytes = Array("Привет🙂".utf8)
        for byte in bytes { screen.append(Data([byte])) }
        #expect(screen.lines[0] == "Done")
        #expect(screen.lines[1] == "Привет🙂")
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorColumn == 8)
        #expect(screen.cursorOffset == "Done\nПривет🙂".utf16.count)
        screen.append("\u{1b}[1;2HX\u{1b}[31m!\u{1b}[0m")
        #expect(screen.lines[0] == "DX!e")
        #expect(!screen.plainText.contains("\u{1b}"))
    }

    @Test func scrollbackAlternateScreenAndResizeAreBounded() {
        var screen = TerminalScreen(columns: 5, rows: 2, scrollbackLimit: 3)
        for index in 0..<40 { screen.append("\(index)\r\n") }
        #expect(screen.lines.count == 5)
        #expect(screen.lines.first == "36")
        let original = screen.plainText
        screen.append("\u{1b}[?1049h\u{1b}[2J\u{1b}[Hmenu")
        #expect(screen.lines.first == "menu")
        screen.append("\u{1b}[?1049l")
        #expect(screen.plainText == original)
        screen.resize(columns: 2, rows: 1)
        #expect(screen.rows == 1)
        #expect(screen.columns == 2)
        #expect(screen.lines.count <= 4)
        #expect(screen.cursorOffset <= screen.plainText.utf16.count)
    }

    @Test func longMaliciousEscapeAndInvalidUTF8StayBounded() {
        var screen = TerminalScreen(columns: 10, rows: 2, scrollbackLimit: 1)
        screen.append("\u{1b}]0;" + String(repeating: "x", count: 100_000) + "\u{7}visible")
        #expect(screen.lines.first == "visible")
        screen.append(Data([0xf0, 0x9f]))
        screen.append("X")
        #expect(screen.plainText.contains("�X"))
        screen.append("\u{1b}[" + String(repeating: "9", count: 10_000) + "H")
        #expect(screen.plainText.utf8.count < 100)
        screen.append(String(repeating: "\u{301}", count: 100_000))
        #expect(screen.plainText.utf8.count < 200)
    }

    @Test func sgrColorsAttributesAndSelectiveResetsProduceAlignedRuns() throws {
        var screen = TerminalScreen(columns: 40, rows: 1)
        screen.append("\u{1b}[1;2;3;4;7;8;9;91;104mA界🙂\u{1b}[22;23;24;27;28;29;39;49mB")
        let styled = try #require(screen.styledRuns.first)
        #expect(styled.text == "A界🙂")
        #expect(styled.attributes.foreground == .indexed(9))
        #expect(styled.attributes.background == .indexed(12))
        #expect(styled.attributes.bold && styled.attributes.faint && styled.attributes.italic)
        #expect(styled.attributes.underline && styled.attributes.inverse && styled.attributes.hidden && styled.attributes.strikethrough)
        #expect(styled.utf16Range == 0..<4)
        #expect(screen.styledRuns.last?.attributes == TerminalAttributes())
        #expect(screen.styledRuns.map(\.text).joined() == screen.plainText)
        #expect(screen.cursorColumn == 6)
        #expect(screen.cursorOffset == 5)
    }

    @Test func extendedColorsSupportSemicolonAndColonForms() {
        var screen = TerminalScreen(columns: 40, rows: 1)
        screen.append("\u{1b}[38;5;202;48;2;10;20;30mA\u{1b}[38:2::40:50:60;48:5:255mB\u{1b}[38:2:70:80:90mC\u{1b}[0mD")
        let runs = screen.styledRuns
        #expect(runs.count == 4)
        #expect(runs[0].attributes.foreground == .indexed(202))
        #expect(runs[0].attributes.background == .rgb(10, 20, 30))
        #expect(runs[1].attributes.foreground == .rgb(40, 50, 60))
        #expect(runs[1].attributes.background == .indexed(255))
        #expect(runs[2].attributes.foreground == .rgb(70, 80, 90))
        #expect(runs[3].attributes == TerminalAttributes())
    }

    @Test func malformedColorGroupsDoNotBecomeUnrelatedAttributes() {
        var screen = TerminalScreen(columns: 40, rows: 1)
        screen.append("\u{1b}[31mA\u{1b}[38;2;999;1;0mB\u{1b}[48;5;999mC\u{1b}[38:2::256:0:0mD\u{1b}[38;2;1mE")
        #expect(screen.styledRuns.count == 1)
        #expect(screen.styledRuns[0].text == "ABCDE")
        #expect(screen.styledRuns[0].attributes.foreground == .indexed(1))
        #expect(!screen.styledRuns[0].attributes.bold)
        #expect(screen.styledRuns[0].attributes.background == nil)
    }

    @Test func coloredEraseScrollbackAndAlternateScreenRetainCellStyles() {
        var screen = TerminalScreen(columns: 5, rows: 2, scrollbackLimit: 2)
        screen.append("\u{1b}[31mred\u{1b}[0m\r\nnext\r\n")
        #expect(screen.lines.first == "red")
        #expect(screen.styledRuns.first?.attributes.foreground == .indexed(1))
        let text = screen.plainText, runs = screen.styledRuns
        screen.append("\u{1b}[?1049h\u{1b}[44m\u{1b}[2J")
        #expect(screen.lines == ["     ", "     "])
        #expect(screen.styledRuns.first?.attributes.background == .indexed(4))
        screen.append("\u{1b}[?1049l")
        #expect(screen.plainText == text)
        #expect(screen.styledRuns == runs)
        screen.append("X")
        #expect(screen.styledRuns.last?.attributes.background == nil)
    }

    @Test func oscTitleAndWorkingDirectoryAreOnlyBoundedMetadata() {
        var screen = TerminalScreen(columns: 30, rows: 1)
        let originalDirectory = FileManager.default.currentDirectoryPath
        for byte in "\u{1b}]2;Работа🙂\u{1b}\\\u{1b}]7;file://localhost/tmp/a%20b\u{7}".utf8 { screen.append(Data([byte])) }
        #expect(screen.title == "Работа🙂")
        #expect(screen.reportedWorkingDirectory?.path == "/tmp/a b")
        #expect(screen.workingDirectoryReportSequence == 1)
        #expect(FileManager.default.currentDirectoryPath == originalDirectory)
        screen.append("\u{1b}]52;c;Y2xpcGJvYXJk\u{7}\u{1b}]777;untrusted-shell-frame\u{7}ok")
        #expect(screen.plainText == "ok")
        #expect(screen.takeResponses().isEmpty)
        screen.append("\u{1b}]7;https://example.com/tmp\u{7}\u{1b}]7;file:///tmp/%00bad\u{7}\u{1b}]7;file:///tmp?q=1\u{7}")
        #expect(screen.reportedWorkingDirectory?.path == "/tmp/a b")
        #expect(screen.workingDirectoryReportSequence == 1)
        screen.append("\u{1b}]2;" + String(repeating: "x", count: 5000) + "\u{7}")
        #expect(screen.title == "Работа🙂")
        screen.append("\u{1b}]0;both\u{7}")
        #expect(screen.title == "both")
    }

    @Test func privateModesAndDeviceStatusAreIndependentAndBounded() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.append("\u{1b}[?1;2004h\u{1b}[?25l\u{1b}[3;4H\u{1b}[5n\u{1b}[6n\u{1b}[c")
        #expect(screen.applicationCursorKeys && screen.bracketedPasteEnabled)
        #expect(!screen.cursorVisible)
        #expect(String(decoding: screen.takeResponses(), as: UTF8.self) == "\u{1b}[0n\u{1b}[3;4R\u{1b}[?1;2c")
        #expect(screen.takeResponses().isEmpty)
        screen.append(String(repeating: "\u{1b}[6n", count: 2000))
        #expect(screen.takeResponses().count <= 4096)
        screen.append("\u{1b}[?1;2004l\u{1b}[?25h")
        #expect(!screen.applicationCursorKeys && !screen.bracketedPasteEnabled && screen.cursorVisible)
        screen.append("\u{1b}[?2004h\u{1b}c")
        #expect(!screen.bracketedPasteEnabled && screen.cursorVisible)
    }

    @Test func graphemeWidthsSurviveSingleByteInput() {
        var screen = TerminalScreen(columns: 40, rows: 2)
        let text = "e\u{301}界👨‍👩‍👧‍👦👍🏽🇫🇷1️⃣❤︎❤️"
        for byte in text.utf8 { screen.append(Data([byte])) }
        #expect(screen.lines.first == text)
        #expect(screen.cursorColumn == 14)
        #expect(screen.cursorOffset == text.utf16.count)
        #expect(screen.styledRuns.map(\.text).joined() == screen.plainText)
    }

    @Test func widthExpansionAtRightMarginWrapsWholeCluster() {
        var screen = TerminalScreen(columns: 4, rows: 3)
        screen.append("abc❤")
        screen.append("\u{fe0f}!")
        #expect(screen.lines[0] == "abc")
        #expect(screen.lines[1] == "❤️!")
        #expect(screen.cursorColumn == 3)
        screen.append("\r\u{1b}[Cz")
        #expect(screen.lines[1] == " z!")
        #expect(!screen.plainText.contains("❤️"))
    }

    @Test func wideCellEditingAndResizeNeverLeaveHalfGlyphs() {
        var screen = TerminalScreen(columns: 8, rows: 1)
        screen.append("A界BC\r\u{1b}[2C\u{1b}[P")
        #expect(!screen.plainText.contains("界"))
        #expect(screen.lines[0] == "A BC")
        screen.append("\r\u{1b}[2J界界")
        screen.resize(columns: 3, rows: 1)
        #expect(screen.lines[0] == "界")
        screen.append("\r\u{1b}[C\u{1b}[K")
        #expect(!screen.plainText.contains("界"))
        #expect(screen.cursorOffset <= screen.plainText.utf16.count)
    }

    @Test func oversizedAndUnsupportedControlStringsNeverLeakPayload() {
        var screen = TerminalScreen(columns: 30, rows: 1)
        screen.append("\u{1b}[" + String(repeating: "9", count: 10_000) + "Hok")
        screen.append("\u{1b}P" + String(repeating: "secret", count: 10_000) + "\u{1b}\\")
        screen.append("\u{1b}_notification\u{1b}\\\u{1b}^private\u{1b}\\")
        screen.append("\u{1b}]2;" + String(repeating: "x", count: 100_000) + "\u{1b}\\!")
        #expect(screen.plainText == "ok!")
        #expect(screen.title == nil)
    }

    @Test func savedCursorRestoresAttributesAndAlternateMargins() {
        var screen = TerminalScreen(columns: 8, rows: 4)
        screen.append("\u{1b}[31m\u{1b}7\u{1b}[32mgreen\u{1b}8R")
        #expect(screen.lines.first == "Rreen")
        #expect(screen.styledRuns.first?.attributes.foreground == .indexed(1))
        screen.append("\u{1b}[0m\u{1b}[2;3r\u{1b}[?1049h\u{1b}[?1049l\u{1b}[3;1H\nX")
        #expect(screen.cursorRow == 2)
        #expect(screen.lines[2] == "X")
    }

    @Test func shrinkingHeightPreservesBottomPromptAndStyledHistory() {
        var screen = TerminalScreen(columns: 12, rows: 5, scrollbackLimit: 2)
        screen.append("discard\r\n\u{1b}[31mred\u{1b}[0m\r\n界\r\nprevious\r\nprompt> ")
        screen.resize(columns: 10, rows: 2)
        #expect(screen.lines == ["red", "界", "previous", "prompt> "])
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorColumn == 8)
        #expect(screen.styledRuns.first?.attributes.foreground == .indexed(1))
        #expect(screen.styledRuns.map(\.text).joined() == screen.plainText)
        #expect(screen.cursorOffset == screen.plainText.utf16.count)
        screen.append("X")
        #expect(screen.lines.last == "prompt> X")
        screen.resize(columns: 10, rows: 4)
        #expect(screen.lines[3] == "prompt> X")
    }

    @Test func resizingAlternatePreservesBothCursorsAndPrimaryHistoryOnly() {
        var screen = TerminalScreen(columns: 12, rows: 4, scrollbackLimit: 4)
        screen.append("one\r\ntwo\r\n\u{1b}[32mthree\u{1b}[0m\r\nmain> ")
        screen.append("\u{1b}[?1049h\u{1b}[4;1H\u{1b}[34m界alt\u{1b}[0m")
        screen.resize(columns: 8, rows: 2)
        #expect(screen.lines == ["", "界alt"])
        #expect(screen.cursorRow == 1)
        screen.append("\u{1b}[?1049l")
        #expect(screen.lines == ["one", "two", "three", "main> "])
        #expect(screen.cursorRow == 1)
        #expect(screen.cursorColumn == 6)
        #expect(screen.styledRuns.contains(where: { $0.text == "three" && $0.attributes.foreground == .indexed(2) }))
        #expect(!screen.plainText.contains("alt"))
        screen.append("X")
        #expect(screen.lines.last == "main> X")
    }

    @Test func colonUnderlineZeroClearsUnderlineWithoutResettingColor() {
        var screen = TerminalScreen(columns: 20, rows: 1)
        screen.append("\u{1b}[31;4:3mA\u{1b}[4:0mB")
        #expect(screen.styledRuns.count == 2)
        #expect(screen.styledRuns[0].attributes.underline)
        #expect(!screen.styledRuns[1].attributes.underline)
        #expect(screen.styledRuns[1].attributes.foreground == .indexed(1))
    }

    @Test func resizingAtPendingWrapDoesNotOverwritePromptEnd() {
        var screen = TerminalScreen(columns: 4, rows: 3)
        screen.append("abcd")
        screen.resize(columns: 4, rows: 2)
        screen.append("X")
        #expect(screen.lines == ["abcd", "X"])
        var wider = TerminalScreen(columns: 4, rows: 2)
        wider.append("ab界")
        wider.resize(columns: 8, rows: 2)
        wider.append("X")
        #expect(wider.lines.first == "ab界X")
        #expect(wider.cursorColumn == 5)
    }
}
