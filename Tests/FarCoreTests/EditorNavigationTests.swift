import Foundation
import Testing
@testable import FarCore

@Suite struct EditorNavigationTests {
    @Test func gotoSupportsFARCoordinateSyntaxAndOmissions() throws {
        let text = "abc\r\n🙂hello\rthird\nlast"
        let origin = try EditorEditing.offset(in: text, line: 2, column: 3)
        func position(_ expression: String, hex: Bool = false) throws -> [Int] {
            let offset = try EditorEditing.gotoOffset(in: text, expression: expression, from: origin, hexadecimal: hex)
            let result = EditorEditing.lineColumn(in: text, offset: offset)
            return [result.line, result.column]
        }
        #expect(try position("+1:-1") == [3, 2])
        #expect(try position("-1 +1") == [1, 4])
        #expect(try position(":1") == [2, 1])
        #expect(try position("3;") == [3, 3])
        #expect(try position("50%:50%") == [3, 3])
        #expect(try position("+25%:-50%") == [3, 1])
        #expect(try position("0x2,$4") == [2, 4])
        #expect(try position("2h.3m") == [2, 3])
        #expect(try position("2 4", hex: true) == [2, 4])
        #expect(try position("100%:100%") == [4, 5])
        #expect(try position("-999999:-999999") == [1, 1])
        #expect(try position("999999:999999") == [4, 5])
        #expect(try position("") == [2, 3])
        #expect(try EditorEditing.gotoOffset(in: "", expression: "100%:100%", from: 0) == 0)
        for invalid in ["x", "0x", "1:2:3", "1 2 3", "--1", "18446744073709551616"] {
            #expect(throws: EditorEditingError.invalidPosition) {
                try EditorEditing.gotoOffset(in: text, expression: invalid, from: origin)
            }
        }
    }

    @Test func bookmarkAnchorsTrackEditsAndRoundTrip() throws {
        var bookmarks = EditorBookmarks()
        bookmarks.set(slot: 0, offset: 0); bookmarks.set(slot: 4, offset: 4); bookmarks.set(slot: 9, offset: 9)
        bookmarks.set(slot: 10, offset: 3); bookmarks.set(slot: 2, offset: -1)
        bookmarks.applyEdit(range: NSRange(location: 2, length: 3), replacementUTF16Length: 1)
        #expect(bookmarks.slots == [0, 4, 9])
        #expect(bookmarks.offset(slot: 0) == 0)
        #expect(bookmarks.offset(slot: 4) == 2)
        #expect(bookmarks.offset(slot: 9) == 7)
        bookmarks.applyEdit(range: NSRange(location: 0, length: 0), replacementUTF16Length: 2)
        #expect(bookmarks.offset(slot: 0) == 2)
        let decoded = try JSONDecoder().decode(EditorBookmarks.self, from: JSONEncoder().encode(bookmarks))
        #expect(decoded == bookmarks)
        bookmarks.remove(slot: 4); #expect(bookmarks.offset(slot: 4) == nil)
        var tracked = EditorBookmarks(); tracked.set(slot: 1, offset: 6)
        tracked.update(from: "ab🙂cd", to: "  ab🙂cd")
        #expect(tracked.offset(slot: 1) == 8)
        tracked.update(from: "  ab🙂cd", to: "ab🙂cd")
        #expect(tracked.offset(slot: 1) == 6)
    }

    @Test func bookmarksSurviveDisjointReplacementsIndentationAndRectangle() throws {
        var bookmarks = EditorBookmarks(); bookmarks.set(slot: 1, offset: 4)
        let replaced = try EditorEditing.replaceAll(in: "cat KEEP cat", query: .init(pattern: "cat"), replacement: "dog")
        bookmarks.apply(changes: try #require(replaced.changes))
        #expect(bookmarks.offset(slot: 1) == 4)
        var indented = EditorBookmarks(); indented.set(slot: 0, offset: 3)
        let edit = try EditorEditing.indent(in: "ab\ncd", selection: NSRange(location: 0, length: 5), tabSize: 2, useSpaces: true)
        indented.apply(changes: try #require(edit.changes))
        #expect(indented.offset(slot: 0) == 7)
        var rectangle = EditorBookmarks(); rectangle.set(slot: 0, offset: 4); rectangle.set(slot: 1, offset: 13)
        let rect = try EditorEditing.replaceRectangle(in: "abc KEEP\nxyz KEEP", rectangle: .init(firstLine: 1, lastLine: 2, firstColumn: 1, lastColumn: 4), replacement: "Z", tabSize: 4)
        rectangle.apply(changes: try #require(rect.changes))
        #expect(rectangle.offset(slot: 0) == 2)
        #expect(rectangle.offset(slot: 1) == 9)
    }

    @Test func allMatchesReportsPositionsContextAndExplicitTruncation() throws {
        let text = "🙂cat cat\r\ncatapult\rcat\n"
        let result = try EditorEditing.allMatches(in: text, query: .init(pattern: "cat", wholeWords: true))
        #expect(result.matches.map(\.line) == [1, 1, 3])
        #expect(result.matches.map(\.column) == [2, 6, 1])
        #expect(result.matches.map(\.range) == [NSRange(location: 2, length: 3), NSRange(location: 6, length: 3), NSRange(location: 20, length: 3)])
        #expect(!result.truncated)
        let limited = try EditorEditing.allMatches(in: text, query: .init(pattern: "cat"), limit: 2)
        #expect(limited.matches.count == 2); #expect(limited.truncated)
        let exact = try EditorEditing.allMatches(in: "cat cat", query: .init(pattern: "cat"), limit: 2)
        #expect(!exact.truncated)
        let crossLine = try EditorEditing.allMatches(in: "cat\ndog", query: .init(pattern: "cat\ndog"))
        #expect(crossLine.matches.first?.range.length == 7)
        let regex = try EditorEditing.allMatches(in: "🙂x\r\n", query: .init(pattern: "(?=.)|$", regex: true))
        #expect(regex.matches.map(\.column) == [1, 2, 3, 1])
        #expect(regex.matches.map(\.line) == [1, 1, 1, 2])
        #expect(throws: EditorEditingError.regexLineTooLong(offset: 0)) {
            try EditorEditing.allMatches(in: String(repeating: "x", count: EditorEditing.maximumRegexLineBytes + 1), query: .init(pattern: "none", regex: true))
        }
    }
}
