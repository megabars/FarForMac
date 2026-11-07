import Foundation
import Testing
@testable import FarCore

@Suite
struct StockEditorPluginTests {
    @Test func autoWrapKeepsSeparatorAndCRLFAndWrapsOnlyChangedLineEnd() throws {
        let text = "one two three four\r\nnext"
        let end = "one two three four".utf16.count
        let previous = EditorAutoWrap.Baseline(line: 1, length: end - 1)
        let result = try #require(try EditorAutoWrap.wrapAfterInput(in: text, caret: end, previous: previous,
            rightMargin: 8, tabSize: 4, autoIndent: false, fallbackEOL: "\n"))
        #expect(result.text == "one two \r\nthree \r\nfour\r\nnext")
        #expect(result.count == 2)
        #expect(result.selection.location == "one two \r\nthree \r\nfour".utf16.count)
        #expect(try EditorAutoWrap.wrapAfterInput(in: text, caret: end - 1, previous: previous,
            rightMargin: 8, tabSize: 4, autoIndent: false, fallbackEOL: "\n") == nil)
        #expect(try EditorAutoWrap.wrapAfterInput(in: text, caret: end, previous: .init(line: 1, length: end),
            rightMargin: 8, tabSize: 4, autoIndent: false, fallbackEOL: "\n") == nil)
    }

    @Test func autoWrapHonorsVisualTabsIndentAndLongWordFallback() throws {
        let text = "\tone two"
        let result = try #require(try EditorAutoWrap.wrapAfterInput(in: text, caret: text.utf16.count,
            previous: .init(line: 1, length: text.utf16.count - 1), rightMargin: 8, tabSize: 4,
            autoIndent: true, fallbackEOL: "\n"))
        #expect(result.text == "\tone \n\ttwo")
        let word = "abcdefgh xyz"
        let fallback = try #require(try EditorAutoWrap.wrapAfterInput(in: word, caret: word.utf16.count,
            previous: .init(line: 1, length: word.utf16.count - 1), rightMargin: 4, tabSize: 4,
            autoIndent: false, fallbackEOL: "\n"))
        #expect(fallback.text == "abcdefgh \nxyz")
    }

    @Test func drawingUsesSameCellOnTurnAndTabSizedSteps() throws {
        var drawing = EditorDrawLine()
        let first = try drawing.draw(in: "", caret: 0, toward: .right, accelerated: false, tabSize: 4, fallbackEOL: "\n")
        #expect(first.text == "─\n")
        #expect(first.selection.location == 0)
        let next = try drawing.draw(in: first.text, caret: first.selection.location, toward: .right,
            accelerated: false, tabSize: 4, fallbackEOL: "\n")
        #expect(next.text == "──\n")
        #expect(next.selection.location == 1)
        let turn = try drawing.draw(in: next.text, caret: next.selection.location, toward: .down,
            accelerated: false, tabSize: 4, fallbackEOL: "\n")
        #expect(turn.text == "─┐\n")
        #expect(turn.selection.location == next.selection.location)
        let down = try drawing.draw(in: turn.text, caret: turn.selection.location, toward: .down,
            accelerated: true, tabSize: 4, fallbackEOL: "\n")
        #expect(down.text == "─┐\n │\n │\n │\n │")
    }

    @Test func drawingMatchesMixedIntersectionsAndExpandsAdjacentTabs() throws {
        var drawing = EditorDrawLine()
        drawing.toggleStyle()
        let text = " │ \t\r\n───\r\n │ "
        let caret = " │ \t\r\n─".utf16.count
        let result = try drawing.draw(in: text, caret: caret, toward: .right,
            accelerated: false, tabSize: 4, fallbackEOL: "\r\n")
        #expect(result.text == " │  \r\n─╪─\r\n │ ")
        #expect(!result.text.contains("\t"))
    }
}
