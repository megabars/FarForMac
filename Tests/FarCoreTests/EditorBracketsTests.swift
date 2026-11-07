import Foundation
import Testing
@testable import FarCore

@Suite struct EditorBracketsTests {
    private func match(_ text: String, _ cursor: Int, direction: EditorBrackets.Direction? = nil,
                       options: EditorBrackets.Options = .init()) throws -> EditorBrackets.Match {
        guard case let .match(result) = EditorBrackets.find(in: text, cursor: cursor, direction: direction, options: options) else {
            Issue.record("Expected a bracket match at \(cursor)"); throw NSError(domain: "BracketsTests", code: 1)
        }
        return result
    }
    @Test func nestedSamePairAcrossUnicodeAndCRLF() throws {
        let text = "🙂{a\r\n{b} [}] end}"
        let units = text as NSString
        let opening = units.range(of: "{").location
        let expected = units.range(of: "}", options: .backwards, range: NSRange(location: 0, length: units.length - 1)).location
        let result = try match(text, opening)
        #expect(result.target == expected) // Other bracket types do not hide a closing brace.
        #expect(try match(text, result.target).target == opening)
        #expect(units.substring(with: result.selection) == "{a\r\n{b} [}")
    }
    @Test func doublePairsAndPriorityUseBothCursorPositions() throws {
        #expect(try match("*/*x*/", 1).target == 3) // FAR tests overlapping double-pair roles.
        #expect(try match("/*x*/", 0).target == 4)
        #expect(try match("/*x*/", 1).target == 3)
        #expect(try match("/*x*/", 3).target == 1)
        #expect(try match("/*x*/", 4).target == 0)
        #expect(try match("<? a <? b ?> c ?>", 0).target == 16)
        var singleFirst = EditorBrackets.Options(); singleFirst.doubleFirst = false
        #expect(try match("<%x%>", 0, options: singleFirst).target == 4)
        #expect(try match("<%x%>", 1, direction: .forward, options: singleFirst).target == 3)
    }
    @Test func equalPairsRequireDirectionAndRespectImmediateEscape() throws {
        #expect(EditorBrackets.find(in: "\"a\"", cursor: 0) == .needsDirection)
        #expect(try match("\"a\"b\"", 2, direction: .backward).target == 0)
        #expect(try match("\"a\"b\"", 2, direction: .forward).target == 4)
        #expect(try match("\"a\\\"b\"", 0, direction: .forward).target == 5)
    }
    @Test func afterBracketAndFailurePreserveOriginalContract() throws {
        #expect(try match("(ab)", 1).selection == NSRange(location: 0, length: 4))
        #expect(try match("(ab)", 4).selection == NSRange(location: 0, length: 4))
        var options = EditorBrackets.Options(); options.ignoreAfter = true
        #expect(EditorBrackets.find(in: "(ab)", cursor: 1, options: options) == .noMatch)
        #expect(EditorBrackets.find(in: "(ab", cursor: 0) == .noMatch)
        #expect(EditorBrackets.find(in: "", cursor: 0) == .noMatch)
        #expect(EditorBrackets.find(in: "[]", cursor: -1) == .noMatch)
    }
    @Test func quotedCharactersAndCustomDescriptions() throws {
        #expect(EditorBrackets.find(in: "'(' x )", cursor: 1) == .noMatch)
        var options = EditorBrackets.Options(); options.ignoreQuoted = true
        #expect(try match("( ')' x )", 0, options: options).target == 8)
        options.singles = "ab"; options.doubles = ""; options.quotes = ""
        #expect(try match("a a b b", 0, options: options).target == 6)
        #expect(try JSONDecoder().decode(EditorBrackets.Options.self, from: JSONEncoder().encode(options)) == options)
        options.singles = "🙂"; #expect(!options.isValid)
        options.singles = "abc"; #expect(!options.isValid)
        options.singles = "a\n"; #expect(!options.isValid)
    }
}
