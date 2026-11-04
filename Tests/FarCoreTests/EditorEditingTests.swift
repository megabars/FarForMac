import Foundation
import Testing
@testable import FarCore

@Suite
struct EditorEditingTests {
    @Test
    func fuzzySearchAndReplacementUseOriginalUnicodeRanges() throws {
        let text = "🙂résumé RÉSUMÉ resumeX _resume resume"
        let query = EditorSearchQuery(pattern: "resume", wholeWords: true, fuzzy: true)
        let results = try EditorEditing.allMatches(in: text, query: query)
        #expect(results.matches.map(\.range) == [NSRange(location: 2, length: 8), NSRange(location: 11, length: 6), (text as NSString).range(of: "resume", options: .backwards)])
        #expect(try EditorEditing.find(in: text, query: query, from: 0) == results.matches.first?.range)
        #expect(try EditorEditing.find(in: text, query: query, from: text.utf16.count, direction: .backward) == results.matches.last?.range)
        #expect(try EditorEditing.find(in: "Résumé", query: .init(pattern: "resume", caseSensitive: true, fuzzy: true), from: 0) == nil)
        let edit = try EditorEditing.replaceAll(in: text, query: query, replacement: "CV")
        #expect(edit.text == "🙂CV CV resumeX _resume CV")
        #expect(edit.count == 3 && edit.selection == NSRange(location: edit.text.utf16.count - 2, length: 2))
        #expect(try EditorEditing.replace(in: "🙂é", range: NSRange(location: 2, length: 2), query: .init(pattern: "e", fuzzy: true), replacement: "x") == "🙂x")
        #expect(throws: EditorEditingError.rangeDoesNotMatch) {
            try EditorEditing.replace(in: "é", range: NSRange(location: 0, length: 1), query: .init(pattern: "e", fuzzy: true), replacement: "x")
        }
        let ligatures = try EditorEditing.replaceAll(in: "ßß ﬁ Æ ①", query: .init(pattern: "s", fuzzy: true), replacement: "X")
        #expect(ligatures.text == "XX ﬁ Æ ①" && ligatures.count == 2)
    }

    @Test
    func fuzzyModesAndStylesRejectUnsupportedCombinationsExplicitly() throws {
        for query in [EditorSearchQuery(pattern: "x", regex: true, fuzzy: true),
                      .init(pattern: "x", regex: true, preserveStyle: true),
                      .init(pattern: "x", fuzzy: true, preserveStyle: true)] {
            #expect(throws: EditorEditingError.incompatibleSearchOptions) { try EditorEditing.validate(query) }
            #expect(throws: EditorEditingError.incompatibleSearchOptions) { try EditorEditing.replaceAll(in: "x", query: query, replacement: "y") }
        }
        #expect(throws: EditorEditingError.foldedQueryIsEmpty) { try EditorEditing.validate(.init(pattern: "́", fuzzy: true)) }
        #expect(try EditorEditing.allMatches(in: "é e e", query: .init(pattern: "e", fuzzy: true), limit: 2).truncated)
    }

    // Golden behavior adapted from Far Group © 2013 preservestyle.cpp inline tests.
    // BSD 3-clause notice: THIRD_PARTY_NOTICES.md. Pinned source linked in EDITOR_REFERENCE.md.
    @Test
    func preserveStyleMatchesFARTokensAndCaseGoldenExamples() throws {
        let examples: [(String, String, String, String)] = [
            ("abc-def-ghi", "pq.RST.Xyz", "AbcDefGhi", "PqRstXyz"),
            ("abc-def-ghi", "pq.RST.Xyz", "ABC_DEF_GHI", "PQ_RST_XYZ"),
            ("abc-def-ghi", "pq.RST.Xyz", "abc.def.ghi", "pq.rst.xyz"),
            ("abc-def-ghi", "pq.RST.Xyz", "abcDefGhi", "pqRstXyz"),
            ("abc-def-ghi", "pq.RST.Xyz", "ABC_Def_Ghi", "PQ_Rst_Xyz"),
            ("AA-B-C", "xxx.Yy.ZZ", "Aa_B_C", "Xxx_Yy_Zz"),
            ("AA-B-C", "xxx.Yy.ZZ", "aa-b-c", "xxx-yy-zz"),
            ("AA-B-C", "xxx.Yy.ZZ", "AA_B_C", "XXX_YY_ZZ"),
            ("AA-B-C", "xxx.Yy.ZZ", "aa.B.C", "xxx.Yy.Zz"),
            ("AA-B-C", "xxx.Yy.ZZ", "Aa.B.c", "Xxx.Yy.zz"),
            ("abc-def-ghi", "pq.RST.uvw.Xyz", "Abc.def.ghi", "Pq.rst.uvw.xyz"),
            ("abc-def-ghi", "pq.RST.uvw.Xyz", "ABC.Def.Ghi", "PQ.Rst.Uvw.Xyz"),
            ("abc-def-ghi", "pq.RST.uvw.Xyz", "abc.Def.ghi", "pq.RST.uvw.Xyz"),
            ("abc-def-ghi", "pq.RST.uvw.Xyz", "ABC.DEF.ghi", "PQ.RST.uvw.Xyz"),
            ("A-B-C", "aa.Bb.cc.DD", "A_B_C", "Aa_Bb_Cc_Dd"),
            ("A-B-C", "aa.Bb.cc.DD", "a-b-c", "aa-bb-cc-dd"),
            ("A-B-C", "aa.Bb.cc.DD", "A.B.c", "Aa.Bb.cc.DD")
        ]
        for (pattern, replacement, source, expected) in examples {
            let query = EditorSearchQuery(pattern: pattern, preserveStyle: true)
            let matches = try EditorEditing.allMatches(in: source, query: query)
            #expect(matches.matches.map(\.range) == [NSRange(location: 0, length: source.utf16.count)])
            #expect(try EditorEditing.replace(in: source, range: matches.matches[0].range, query: query, replacement: replacement) == expected)
            let edit = try EditorEditing.replaceAll(in: source, query: query, replacement: replacement)
            #expect(edit.text == expected && edit.count == 1)
            #expect(edit.selection == NSRange(location: 0, length: expected.utf16.count))
        }
    }

    @Test
    func preserveStyleUsesContextAndLiteralFallbackLikeFAR() throws {
        let examples = [("ijk.Zzz", "mno.Pqr.Stu.Zzz"), ("AAA-ijk", "AAA-mno-pqr-stu"),
                        ("aaa-ijk_ZZZ", "aaa-mno_PQR_STU_ZZZ"), ("AaaIjk", "AaaMnoPqrStu"),
                        ("0_ijk_9", "0_mno_Pqr_Stu_9"), (">ijk<", ">mnopqrstu<")]
        for (source, expected) in examples {
            #expect(try EditorEditing.replaceAll(in: source, query: .init(pattern: "ijk", preserveStyle: true), replacement: "MnoPqrStu").text == expected)
        }
        // PreserveStyleReplaceString declines this internal camel boundary; strmix.cpp
        // ordinary literal fallback keeps only the source's first letter case.
        #expect(try EditorEditing.replaceAll(in: "Ab.cD", query: .init(pattern: "ab.cd", preserveStyle: true), replacement: "wx-yz").text == "Wx-yz")
        #expect(try EditorEditing.replaceAll(in: "ab.cD", query: .init(pattern: "ab.cd", preserveStyle: true), replacement: "WX-YZ").text == "wX-YZ")
        // Unknown mixed case remains unchanged rather than guessing a case style.
        #expect(try EditorEditing.replaceAll(in: "mIxEd", query: .init(pattern: "mixed", preserveStyle: true), replacement: "NeW").text == "neW")
    }

    @Test
    func preserveStyleFindAllReplaceAndBoundariesShareRanges() throws {
        let text = "🙂UserName USER_NAME user-name _user_name user_nameX user.name"
        let query = EditorSearchQuery(pattern: "user_name", wholeWords: true, preserveStyle: true)
        let matches = try EditorEditing.allMatches(in: text, query: query)
        #expect(matches.matches.count == 4)
        for match in matches.matches {
            #expect(try EditorEditing.find(in: text, query: query, from: match.range.location) == match.range)
        }
        #expect(try EditorEditing.find(in: text, query: query, from: text.utf16.count, direction: .backward) == matches.matches.last?.range)
        let edit = try EditorEditing.replaceAll(in: text, query: query, replacement: "account_id")
        #expect(edit.text == "🙂AccountId ACCOUNT_ID account-id _user_name user_nameX account.id")
        #expect(edit.changes?.map(\.range) == matches.matches.map(\.range))
        #expect(try EditorEditing.find(in: "USER_NAME", query: .init(pattern: "user_name", caseSensitive: true, preserveStyle: true), from: 0) == nil)
        #expect(try EditorEditing.replaceAll(in: "userName user_name", query: .init(pattern: "user_name", preserveStyle: true), replacement: "").text == " ")
    }

    @Test
    func preserveStyleBoundsAdversarialNearMatchesBeforeEditing() throws {
        let pattern = "a_" + String(repeating: "b", count: 4094)
        let source = String(repeating: "a_", count: 10_000)
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: EditorEditingError.styleSearchLimit) {
            try EditorEditing.replaceAll(in: source, query: .init(pattern: pattern, preserveStyle: true), replacement: "x")
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
        // A one-token match expanded into a large neighboring identifier must
        // share the operation budget instead of rescanning it for every edit.
        #expect(throws: EditorEditingError.styleSearchLimit) {
            try EditorEditing.replaceAll(in: String(repeating: "a", count: 50_000), query: .init(pattern: "a", preserveStyle: true), replacement: "OneTwo")
        }
    }

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
        for query in [EditorSearchQuery(pattern: "🙂"), .init(pattern: "🙂", fuzzy: true), .init(pattern: "🙂", preserveStyle: true)] {
            #expect(try EditorEditing.find(in: "🙂🙂", query: query, from: 1, direction: .backward) == NSRange(location: 0, length: 2))
        }
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
