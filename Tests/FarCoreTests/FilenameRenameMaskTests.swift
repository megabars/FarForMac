import Foundation
import Testing
@testable import FarCore

@Suite
struct FilenameRenameMaskTests {
    // Representative independent assertions against the pinned upstream
    // ConvertWildcards behavior, including positional rather than glob matching.
    @Test func farDestinationMaskPositionsStarsAndDots() throws {
        let cases: [(String, String, String)] = [
            ("report.part.txt", "*.bak", "report.part.bak"),
            ("report.part.txt", "*?.bak", "report.part.txt.bak"),
            ("1234.txt", "A?Z*", "A2Z4.txt"),
            ("a.b.c", "?????.?????", "a.b"),
            ("abcd_12345.txt", "*_NEW.*", "abcd_NEW.txt"),
            ("a.b.c", "?x.????999.*rForTheCourse", "ax.b999.crForTheCourse"),
            ("1.2", "test.*", "test.2"),
            ("1.2", "t*?.", "t.2"),
            ("1.2", "t?*.", "t"),
            ("1.2", "*.*.2", "1.2.2"),
            ("README", "*.bak", "README.bak"),
            ("README", "*.", "README"),
            (".hidden", "*.bak", ".bak"),
            ("a.", "*", "a"),
            ("1.2", "[t-]*", "[t-].2"),
            ("a.txt", "literal.", "literal."),
            ("a.txt", "**", "a.txt*"),
            ("1.2", "*?**??*???*.??*?", "1.2*"),
            ("a.txt", "{name}.*", "{name}.txt"),
            ("a.txt", "*[a-c].bak", "a.txt[a-c].bak"),
        ]
        for (source, mask, expected) in cases {
            #expect(try FilenameRenameMask(mask).destinationName(for: source) == expected,
                    "source=\(source), mask=\(mask)")
        }
    }

    @Test func utf16SemanticsPreserveUnicodeOrRejectSplitSurrogates() throws {
        #expect(try FilenameRenameMask("??-*").destinationName(for: "😀.txt") == "😀-.txt")
        #expect(try FilenameRenameMask("*.bak").destinationName(for: "cafe\u{301}.txt") == "cafe\u{301}.bak")
        #expect(Array(try FilenameRenameMask("*.bak").destinationName(for: "cafe\u{301}.txt").utf16) == Array("cafe\u{301}.bak".utf16))
        #expect(try FilenameRenameMask("?-*").destinationName(for: "Я.txt") == "Я-.txt")
        #expect(try FilenameRenameMask("??.bak").destinationName(for: "😀.txt") == "😀.bak")
        #expect(throws: (any Error).self) { try FilenameRenameMask("?.bak").destinationName(for: "😀.txt") }
        #expect(throws: (any Error).self) { try FilenameRenameMask("X?*").destinationName(for: "😀.txt") }
    }

    @Test func rejectsPathsNULAndExcessiveMasks() throws {
        for mask in ["", "../*.txt", "/tmp/name", "folder\\*.txt", "name\0suffix", String(repeating: "?", count: 4_097)] {
            #expect(throws: (any Error).self) { try FilenameRenameMask(mask) }
        }
        for source in ["", "dir/file", "dir\\file", "a\0b"] {
            #expect(throws: (any Error).self) { try FilenameRenameMask("*.bak").destinationName(for: source) }
        }
    }
}
