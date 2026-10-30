import Foundation
import Testing
@testable import FarCore

@Suite
struct EditorEditingTests {
    @Test
    func searchesUnicodeWholeWordsAndOverlapsWithoutWrapping() throws {
        let text = "🙂Кот котик _кот кот\u{301} КОТ"
        let query = EditorSearchQuery(pattern: "кот", wholeWords: true)
        #expect(try EditorEditing.find(in: text, query: query, from: 0) == NSRange(location: 2, length: 3))
        #expect(try EditorEditing.find(in: text, query: query, from: 3) == (text as NSString).range(of: "КОТ"))
        #expect(try EditorEditing.find(in: text, query: .init(pattern: "КОТ", caseSensitive: true), from: 0) == (text as NSString).range(of: "КОТ"))
        #expect(try EditorEditing.find(in: text, query: query, from: text.utf16.count) == nil)
        #expect(try EditorEditing.find(in: "ababa", query: .init(pattern: "aba"), from: 5, direction: .backward) == NSRange(location: 2, length: 3))
        #expect(try EditorEditing.find(in: "ababa", query: .init(pattern: "aba", regex: true), from: 5, direction: .backward) == NSRange(location: 2, length: 3))
        #expect(try EditorEditing.find(in: "ababa", query: .init(pattern: "aba"), from: 2, direction: .backward) == NSRange(location: 0, length: 3))
        #expect(try EditorEditing.find(in: text, query: query, from: 0, direction: .backward) == nil)
    }

    @Test
    func regexSearchUsesLogicalLinesLookbehindAndWholeWords() throws {
        let text = "🙂first\r\nsecond\rthird\nfourth\u{85}last\u{2028}"
        #expect(try EditorEditing.find(in: text, query: .init(pattern: "^second$", regex: true), from: 0) == NSRange(location: 9, length: 6))
        #expect(try EditorEditing.find(in: text, query: .init(pattern: "^", regex: true), from: 1) == NSRange(location: 9, length: 0))
        #expect(try EditorEditing.find(in: "ababa", query: .init(pattern: "(?<=ab)aba", regex: true), from: 1) == NSRange(location: 2, length: 3))
        let query = EditorSearchQuery(pattern: "(cat)", regex: true, wholeWords: true)
        #expect(try EditorEditing.find(in: "cats cat", query: query, from: 0) == NSRange(location: 5, length: 3))
        #expect(try EditorEditing.replace(in: "cats cat", range: NSRange(location: 5, length: 3), query: query, replacement: "$1!") == "cats cat!")
    }

    @Test
    func replacementsPreserveEndingsAndExpandICUCaptures() throws {
        let text = "a1\r\na2\ra3\n"
        let edit = try EditorEditing.replaceAll(in: text, query: .init(pattern: "a([0-9])", regex: true), replacement: "<$1>")
        #expect(edit.text == "<1>\r\n<2>\r<3>\n")
        #expect(edit.count == 3)
        #expect(edit.selection == NSRange(location: 9, length: 3))
        #expect(try EditorEditing.replaceAll(in: "x x", query: .init(pattern: "x"), replacement: "$1").text == "$1 $1")
        #expect(try EditorEditing.replaceAll(in: "x", query: .init(pattern: "z"), replacement: "q").count == 0)
        #expect(throws: EditorEditingError.rangeDoesNotMatch) {
            try EditorEditing.replace(in: "cat", range: NSRange(location: 0, length: 2), query: .init(pattern: "cat"), replacement: "dog")
        }
        #expect(throws: EditorEditingError.invalidRange) {
            try EditorEditing.replace(in: "🙂", range: NSRange(location: 1, length: 1), query: .init(pattern: ".", regex: true), replacement: "")
        }
    }

    @Test
    func emptyRegexMatchesAdvanceByScalarsAndTerminate() throws {
        let edit = try EditorEditing.replaceAll(in: "🙂x\r\n", query: .init(pattern: "(?=.)|$", regex: true), replacement: "|")
        #expect(edit.text == "|🙂|x|\r\n|")
        #expect(edit.count == 4)
        #expect(try EditorEditing.find(in: "🙂x", query: .init(pattern: ".", regex: true), from: 1) == NSRange(location: 2, length: 1))
        #expect(try EditorEditing.find(in: "🙂🙂", query: .init(pattern: "🙂"), from: 1) == NSRange(location: 2, length: 2))
    }

    @Test
    func regexFailuresAreExplicitAndEarlierLongLinesCanBeSkipped() throws {
        #expect(throws: EditorEditingError.emptyQuery) { try EditorEditing.validate(.init(pattern: "")) }
        #expect(throws: EditorEditingError.queryTooLong) { try EditorEditing.validate(.init(pattern: String(repeating: "a", count: 4097))) }
        #expect(throws: (any Error).self) { try EditorEditing.validate(.init(pattern: "[", regex: true)) }
        for pattern in ["a\nb", #"a\nb"#, #"(?s)a.*b"#, #"\Afile"#] {
            #expect(throws: EditorEditingError.unsupportedMultilineRegex) { try EditorEditing.validate(.init(pattern: pattern, regex: true)) }
        }
        try EditorEditing.validate(.init(pattern: #"\\n"#, regex: true))
        let prefix = String(repeating: "a", count: EditorEditing.maximumRegexLineBytes + 1)
        #expect(throws: EditorEditingError.regexLineTooLong(offset: 0)) {
            try EditorEditing.find(in: prefix, query: .init(pattern: "missing", regex: true), from: 0)
        }
        #expect(try EditorEditing.find(in: prefix + "\nneedle", query: .init(pattern: "needle", regex: true), from: prefix.utf16.count + 1) == NSRange(location: prefix.utf16.count + 1, length: 6))
        #expect(try EditorEditing.find(in: prefix + "needle", query: .init(pattern: "needle"), from: 0)?.location == prefix.utf16.count)
    }

    @Test
    func catastrophicRegexHasCooperativeDeadline() throws {
        let text = String(repeating: "a", count: 4000) + "!"
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: EditorEditingError.regexDeadlineExceeded) {
            try EditorEditing.find(in: text, query: .init(pattern: "^(a+)+$", regex: true), from: 0)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test
    func lineTableTreatsCRLFAsOneEndingAndColumnsAsScalars() throws {
        let text = "🙂e\u{301}\r\nаб\rx\u{2028}"
        #expect(EditorEditing.lineColumn(in: text, offset: 1).line == 1)
        #expect(EditorEditing.lineColumn(in: text, offset: 1).column == 1)
        #expect(EditorEditing.lineColumn(in: text, offset: 4).column == 4)
        #expect(EditorEditing.lineColumn(in: text, offset: 5).line == 1)
        #expect(EditorEditing.lineColumn(in: text, offset: 6).line == 2)
        #expect(try EditorEditing.offset(in: text, line: 1, column: 2) == 2)
        #expect(try EditorEditing.offset(in: text, line: 1, column: 4) == 4)
        #expect(try EditorEditing.offset(in: text, line: 2) == 6)
        #expect(try EditorEditing.offset(in: text, line: 4) == text.utf16.count)
        #expect(throws: EditorEditingError.invalidPosition) { try EditorEditing.offset(in: text, line: 0) }
        #expect(throws: EditorEditingError.invalidPosition) { try EditorEditing.offset(in: text, line: 2, column: 4) }
    }

    @Test
    func indentationExcludesFollowingLineAndPreservesEndingsAndSelection() throws {
        let text = "a\r\nb\nc"
        let selection = NSRange(location: 0, length: 5)
        let edit = try EditorEditing.indent(in: text, selection: selection, tabSize: 2, useSpaces: true)
        #expect(edit.text == "  a\r\n  b\nc")
        #expect(edit.count == 2)
        #expect(edit.selection == NSRange(location: 2, length: 7))
        let restored = try EditorEditing.indent(in: edit.text, selection: edit.selection, tabSize: 2, useSpaces: true, outdent: true)
        #expect(restored.text == text)
        #expect(restored.selection == selection)
        let caret = try EditorEditing.indent(in: "🙂", selection: NSRange(location: 2, length: 0), tabSize: 4, useSpaces: false)
        #expect(caret.text == "\t🙂")
        #expect(caret.selection == NSRange(location: 3, length: 0))
        #expect(try EditorEditing.indent(in: "\tx\n x", selection: NSRange(location: 0, length: 5), tabSize: 4, useSpaces: false, outdent: true).text == "x\nx")
    }

    @Test
    func rectanglesRespectTabsGraphemesAndShortLines() throws {
        let text = "\tAe\u{301}🙂\r\nx\r\n123456"
        let rectangle = EditorRectangle(firstLine: 1, lastLine: 3, firstColumn: 3, lastColumn: 7)
        #expect(try EditorEditing.extractRectangle(in: text, rectangle: rectangle, tabSize: 4) == "  Ae\u{301}\n\n3456")
        let deleted = try EditorEditing.replaceRectangle(in: text, rectangle: rectangle, replacement: "", tabSize: 4)
        #expect(deleted.text == "  🙂\r\nx\r\n12")
        let inserted = try EditorEditing.replaceRectangle(in: text, rectangle: rectangle, replacement: "Q", tabSize: 4)
        #expect(inserted.text == "  Q🙂\r\nx Q\r\n12Q")
        #expect(inserted.count == 3)
        let reversed = EditorRectangle(firstLine: 3, lastLine: 1, firstColumn: 7, lastColumn: 3)
        #expect(try EditorEditing.extractRectangle(in: text, rectangle: reversed, tabSize: 4) == EditorEditing.extractRectangle(in: text, rectangle: rectangle, tabSize: 4))
    }

    @Test
    func rectangularPasteMapsRowsAndAppendsUsingDocumentEOL() throws {
        let rectangle = EditorRectangle(firstLine: 2, lastLine: 2, firstColumn: 3, lastColumn: 3)
        let edit = try EditorEditing.replaceRectangle(in: "a\r\nb", rectangle: rectangle, replacement: "X\nY", tabSize: 4)
        #expect(edit.text == "a\r\nb X\r\n  Y")
        let deletion = try EditorEditing.replaceRectangle(in: "x", rectangle: .init(firstLine: 4, lastLine: 8, firstColumn: 5, lastColumn: 9), replacement: "", tabSize: 4)
        #expect(deletion.text == "x")
        #expect(deletion.count == 0)
        #expect(try EditorEditing.replaceRectangle(in: "\tx", rectangle: .init(firstLine: 1, lastLine: 1, firstColumn: 2, lastColumn: 2), replacement: "", tabSize: 4).text == "\tx")
    }

    @Test
    func replacementExpansionAndMatchCountAreBoundedBeforeMutation() throws {
        let many = String(repeating: "x", count: EditorEditing.maximumMatches + 1)
        #expect(throws: EditorEditingError.operationTooLarge) {
            try EditorEditing.replaceAll(in: many, query: .init(pattern: "x"), replacement: "")
        }
        let huge = String(repeating: "a", count: EditorEditing.maximumOutputUTF16)
        #expect(throws: EditorEditingError.operationTooLarge) {
            try EditorEditing.replace(in: "xx", range: NSRange(location: 0, length: 1), query: .init(pattern: "x"), replacement: huge)
        }
        #expect(throws: EditorEditingError.operationTooLarge) {
            try EditorEditing.replaceAll(in: "xx", query: .init(pattern: "x"), replacement: huge)
        }
        let captured = String(repeating: "a", count: 1024)
        #expect(throws: EditorEditingError.operationTooLarge) {
            try EditorEditing.replace(in: captured, range: NSRange(location: 0, length: 1024),
                query: .init(pattern: "(a+)", regex: true), replacement: String(repeating: "$1", count: 20_000))
        }
    }

    @Test
    func rectangleRejectsOverflowCoordinatesAndExcessivePadding() throws {
        for coordinate in [Int.max, Int.min, 0, EditorEditing.maximumRectangleCoordinate + 1] {
            let rectangle = EditorRectangle(firstLine: 1, lastLine: 1, firstColumn: coordinate, lastColumn: 2)
            #expect(throws: EditorEditingError.invalidRectangleCoordinate) {
                try EditorEditing.replaceRectangle(in: "x", rectangle: rectangle, replacement: "a", tabSize: 4)
            }
            #expect(throws: EditorEditingError.invalidRectangleCoordinate) {
                try EditorEditing.extractRectangle(in: "x", rectangle: rectangle, tabSize: 4)
            }
        }
        #expect(throws: EditorEditingError.operationTooLarge) {
            try EditorEditing.replaceRectangle(in: String(repeating: "\n", count: 20),
                rectangle: .init(firstLine: 1, lastLine: 21, firstColumn: 1_000_000, lastColumn: 1_000_000),
                replacement: "x", tabSize: 4)
        }
        #expect(throws: EditorEditingError.operationTooLarge) {
            try EditorEditing.replaceRectangle(in: "", rectangle: .init(firstLine: 1_000_000, lastLine: 1_000_000, firstColumn: 1, lastColumn: 1), replacement: "x", tabSize: 4)
        }
        let manyLines = String(repeating: "\n", count: 70_000)
        #expect(throws: EditorEditingError.operationTooLarge) {
            try EditorEditing.indent(in: manyLines, selection: NSRange(location: 0, length: manyLines.utf16.count), tabSize: 256, useSpaces: true)
        }
    }
}
