import Foundation
import Testing
@testable import FarCore

/// FAR normalization golden cases adapted from Far Group © 2017;
/// see THIRD_PARTY_NOTICES.md, far/string_utils.cpp at the pinned reference.
@Suite struct SearchTextFoldingTests {
    @Test func pinnedFARNormalizationCasesAndCaseIndependence() throws {
        let cases = [("їёй", "іеи"), ("Æﬁ", "AEfi"), ("Ĝŕžèģōŗż", "Grzegorz"),
                     ("𝔇𝔬𝔯𝔦𝔪𝔢", "Dorime"), ("⓪①②③④⑤", "012345"), ("⅓/¼", "1⁄3/1⁄4"),
                     ("ßß", "ssss"), ("ざじず", "さしす")]
        for (original, normalized) in cases {
            #expect(SearchTextFolding.fold(original, caseSensitive: true) == normalized)
        }
        #expect(SearchTextFolding.fold("Œœ Ææ ẞß ١۲３", caseSensitive: true) == "OEoe AEae SSss 123")
        #expect(try SearchTextFolding("ÉCOLE", caseSensitive: true).firstRange(of: "ecole") == nil)
        #expect(try SearchTextFolding("ÉCOLE", caseSensitive: true).firstRange(of: "ECOLE") == NSRange(location: 0, length: 5))
        #expect(try SearchTextFolding("ÉCOLE").firstRange(of: "ecole") == NSRange(location: 0, length: 5))
    }

    @Test func mappedRangesCoverExpansionsSupplementaryScalarsAndDiscardedMarks() throws {
        let text = "🙂 Æ ß e\u{301}\u{308} 𝔇"
        let folded = try SearchTextFolding(text)
        #expect(folded.firstRange(of: "ae") == NSRange(location: 3, length: 1))
        #expect(folded.firstRange(of: "s") == NSRange(location: 5, length: 1))
        #expect(folded.firstRange(of: "e", in: NSRange(location: 7, length: 6)) == NSRange(location: 7, length: 3))
        #expect(folded.firstRange(of: "d") == NSRange(location: 11, length: 2))
        #expect(folded.firstRange(of: "e", in: NSRange(location: 8, length: 5)) == nil)
        #expect(try SearchTextFolding("\u{301}e\u{301}").firstRange(of: "e") == NSRange(location: 1, length: 2))
        #expect(try SearchTextFolding("ßß").firstRange(of: "s", in: NSRange(location: 1, length: 1)) == NSRange(location: 1, length: 1))
        #expect(try SearchTextFolding("ababa").firstRange(of: "aba", backwards: true) == NSRange(location: 2, length: 3))
        #expect(try SearchTextFolding("abc").firstRange(of: "\u{301}") == nil)
    }

    @Test func alphabeticVowelMarksAndJoinersArePreserved() {
        // FAR preserves marks classified as alphabetic/lexical. Unicode's
        // Alphabetic property supplies the macOS adaptation of that category.
        #expect(SearchTextFolding.fold("कि", caseSensitive: true) == "कि")
        #expect(SearchTextFolding.fold("a\u{200D}b", caseSensitive: true) == "a\u{200D}b")
    }
    @Test func expansionLimitFailsBeforeOversizedMapsAreBuilt() throws {
        #expect(SearchTextFolding.maximumFoldedUTF16 == 16 * 1_024 * 1_024)
        #expect(throws: SearchTextFoldingError.expansionTooLarge(limit: 32)) {
            try SearchTextFolding(String(repeating: "\u{FDFA}", count: 3), maximumFoldedUTF16: 32)
        }
        #expect(throws: SearchTextFoldingError.expansionTooLarge(limit: 4)) {
            try SearchTextFolding("abcde", maximumFoldedUTF16: 4)
        }
        #expect(try SearchTextFolding("abcd", maximumFoldedUTF16: 4).firstRange(of: "bc") == NSRange(location: 1, length: 2))
    }

}
