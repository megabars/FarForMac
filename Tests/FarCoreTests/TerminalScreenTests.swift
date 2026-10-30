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
}
