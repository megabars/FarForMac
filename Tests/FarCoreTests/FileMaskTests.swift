import Foundation
import Testing
@testable import FarCore

@Suite
struct FileMaskTests {
    @Test
    func anchoredWildcardsKeepDotsLiteral() throws {
        let mask = try FileMask("f*.ex?")
        #expect(mask.matches("ftp.exe"))
        #expect(mask.matches("f.ext"))
        #expect(!mask.matches("prefix-ftp.exe"))
        #expect(!mask.matches("ftpXexe"))
        #expect(!mask.matches("ftp.exe.bak"))
        let exact = try FileMask("report.txt")
        #expect(exact.matches("REPORT.TXT"))
        #expect(!exact.matches("reportAtxt"))
    }

    @Test
    func farAllFilesMaskIncludesDotlessAndHiddenNames() throws {
        let mask = try FileMask("*.*")
        for name in ["README", ".hidden", "archive.tar.gz", "Новая папка"] {
            #expect(mask.matches(name))
        }
        #expect(try FileMask("*").matches(""))
        #expect(!(try FileMask("?")).matches(""))
    }

    @Test
    func includeListsAndExclusionsCombineWithoutCursorOrFilesystemState() throws {
        let mask = try FileMask(" *.txt ; *.md, README | secret*;*.bak ")
        #expect(mask.matches("note.TXT"))
        #expect(mask.matches("README"))
        #expect(mask.matches("guide.md"))
        #expect(!mask.matches("secret.txt"))
        #expect(!mask.matches("guide.md.bak"))
        #expect(!mask.matches("image.png"))
        let onlyExclusions = try FileMask("|*.bak,*.tmp")
        #expect(onlyExclusions.matches("README"))
        #expect(!onlyExclusions.matches("cache.TMP"))
        #expect(!(try FileMask("*.*|*.bak")).matches("backup.bak"))
    }

    @Test
    func characterClassesSupportListsRangesAndNegation() throws {
        let mixed = try FileMask("[a-cx]?.[tT][xX][tT]")
        #expect(mixed.matches("B1.txt"))
        #expect(mixed.matches("xz.TXT"))
        #expect(!mixed.matches("dz.txt"))
        #expect(!mixed.matches("abz.txt"))
        let negated = try FileMask("[!a-c]*")
        #expect(negated.matches("zebra"))
        #expect(!negated.matches("Apple"))
        #expect(!negated.matches(""))
        #expect(try FileMask("[-a]").matches("-"))
        #expect(try FileMask("[a-]").matches("-"))
        #expect(try FileMask("file[;,]name").matches("file,name"))
        #expect(try FileMask("file[;,]name").matches("file;name"))
        #expect(try FileMask("[[]").matches("["))
        #expect(try FileMask("[*][?]").matches("*?"))
    }

    @Test
    func unicodeMatchingUsesWholeGraphemesAndCaseInsensitiveCyrillic() throws {
        #expect(try FileMask("ОТЧЁТ-?.txt").matches("отчёт-я.TXT"))
        #expect(try FileMask("[а-я].txt").matches("Я.TXT"))
        #expect(try FileMask("?.txt").matches("👨‍👩‍👧‍👦.txt"))
        #expect(try FileMask("?.txt").matches("🇫🇷.txt"))
        #expect(!(try FileMask("??.txt")).matches("🇫🇷.txt"))
        #expect(try FileMask("café.txt").matches("cafe\u{301}.TXT"))
        #expect(try FileMask("[é].txt").matches("e\u{301}.txt"))
        #expect(try FileMask("[!👨‍👩‍👧‍👦].txt").matches("🙂.txt"))
    }

    @Test(arguments: ["", "   ", "*||*.txt", "a|b|c", ",a", "a;", "a,,b", "[", "[]", "[!]", "[abc", "abc]", "[z-a]", "<arc>", "*.txt,<arc>"])
    func malformedMasksHaveRussianErrors(_ pattern: String) {
        #expect {
            try FileMask(pattern)
        } throws: { error in
            error.localizedDescription.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil
        }
    }

    @Test
    func literalRegexPunctuationHasNoRegexSemantics() throws {
        let mask = try FileMask("file+(1).txt")
        #expect(mask.matches("file+(1).txt"))
        #expect(!mask.matches("file1.txt"))
    }

    @Test
    func repeatedStarsDoNotCauseRecursiveBacktracking() throws {
        let mask = try FileMask(String(repeating: "*a", count: 150) + "*b")
        // Test polynomial glob matching independently of the interactive 10 ms budget.
        // Deadline enforcement has dedicated tests below; scheduler load is not a mismatch.
        #expect(try mask.matchesChecked(String(repeating: "a", count: 200) + "b", timeLimit: 1))
        #expect(try !mask.matchesChecked(String(repeating: "a", count: 200) + "c", timeLimit: 1))
        #expect(try FileMask("***.txt").matches("a.txt"))
    }

    @Test
    func quotesProtectMaskDelimitersAndPreserveSpaces() throws {
        let mask = try FileMask(#""file,name.txt";"a;b|c";" spaced "|"secret,name.txt""#)
        #expect(mask.matches("file,name.txt"))
        #expect(mask.matches("a;b|c"))
        #expect(mask.matches(" spaced "))
        #expect(!mask.matches("spaced"))
        #expect(!mask.matches("secret,name.txt"))
        #expect(try FileMask(#""*.txt""#).matches("NOTE.TXT"))
        #expect(try FileMask("*.txt|").matches("a.txt"))
        #expect(try FileMask("|").matches("README"))
    }

    @Test
    func explicitRegexSearchesInsideNameAndHonorsOptions() throws {
        #expect(try FileMask("/(eng|rus)/i").matches("my-RUS-document.txt"))
        #expect(!(try FileMask("/rus/")).matches("RUS"))
        #expect(try FileMask("/^line$/m").matches("first\nline\nlast"))
        #expect(try FileMask("/a.b/s").matches("a\nb"))
        #expect(try FileMask("/ FOO bar /ix").matches("xFOOBARx"))
        #expect(try FileMask(#"/[,;|]+/,/a\/b/"#).matches("a/b"))
        #expect(try FileMask(#"/[,;|]+/,/a\/b/"#).matches("name;part"))
        #expect(try FileMask(#"/(?<word>abc)\k<word>/"#).matches("xabcabcx"))
        #expect(!(try FileMask(#"*|/^pict\d{1,3}\.gif$/i"#)).matches("PICT123.GIF"))
        #expect(try FileMask(#"*|/^pict\d{1,3}\.gif$/i"#).matches("pict1234.gif"))
        #expect(try FileMask(#"/"quoted",value;other|thing/"#).matches(#""quoted",value;other"#))
    }

    @Test
    func groupsExpandRecursivelyAndComposeWithExclusions() throws {
        let groups = ["text": "*.txt;*.md", "docs": "<text>,README", "public": "<docs>|secret*", "literal": #""file,name""#]
        let docs = try FileMask("<docs>|*.md", groups: groups)
        #expect(docs.matches("readme"))
        #expect(docs.matches("a.TXT"))
        #expect(!docs.matches("a.md"))
        #expect(!(try FileMask("<public>", groups: groups)).matches("secret.txt"))
        #expect(try FileMask("*|<text>", groups: groups).matches("photo.png"))
        #expect(!(try FileMask("*|<text>", groups: groups)).matches("note.md"))
        #expect(try FileMask("<literal>", groups: groups).matches("file,name"))
        // Angle brackets in regex named captures and quoted filename masks are opaque.
        #expect(try FileMask(#""<missing>""#, groups: groups).matches("<missing>"))
    }

    @Test(arguments: [#""unclosed"#, #"a"b""#, #""a"suffix"#, "<>", "<missing>", "a>", "<missing", "/unclosed", "/[/", "/x/z", "/x/iiZ", "*.txt|*.bak|*.tmp"])
    func advancedSyntaxErrorsAreRussian(_ pattern: String) {
        #expect {
            try FileMask(pattern)
        } throws: { error in
            error.localizedDescription.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil
        }
    }

    @Test
    func invalidGroupsAndExpansionLimitsFailDuringConstruction() {
        #expect(throws: (any Error).self) { try FileMask("<a>", groups: ["a": "<b>", "b": "<a>"]) }
        #expect(throws: (any Error).self) { try FileMask("<a>", groups: ["a": "<unknown>"]) }
        #expect(throws: (any Error).self) { try FileMask("<a>|x", groups: ["a": "*|secret*"]) }
        var deep = [String: String]()
        for index in 0..<20 { deep["g\(index)"] = index == 19 ? "*" : "<g\(index + 1)>" }
        #expect(throws: (any Error).self) { try FileMask("<g0>", groups: deep) }
        #expect(throws: (any Error).self) { try FileMask(String(repeating: "a", count: 4_097)) }
        #expect(throws: (any Error).self) { try FileMask("<long>", groups: ["long": String(repeating: "a", count: 4_097)]) }
        #expect(throws: (any Error).self) { try FileMask("<a>", groups: ["a": String(repeating: "<b>,", count: 100) + "<b>", "b": String(repeating: "x", count: 1_000)]) }
        let many = [String](repeating: "x", count: 400).joined(separator: ",")
        // Expansion can stay below the length ceiling but exceed the mask count ceiling.
        #expect(throws: (any Error).self) { try FileMask("<a>,<a>,<a>", groups: ["a": many]) }
        let references = [String](repeating: "<b>", count: 200).joined(separator: ",")
        let leaves = [String](repeating: "<c>", count: 6).joined(separator: ",")
        #expect(throws: (any Error).self) { try FileMask("<a>", groups: ["a": references, "b": leaves, "c": "x"]) }
    }

    @Test
    func bulkMatchingUsesOneDeadlineAndReturnsOnlyCompleteResults() throws {
        let mask = try FileMask("*.txt|secret*")
        #expect(try mask.matchingNames(["a.txt", "a.md", "secret.txt", "b.TXT"]) == ["a.txt", "b.TXT"])
        #expect(throws: (any Error).self) { try mask.matchingNames(["a.txt"], timeLimit: 0) }
        #expect(throws: (any Error).self) { try mask.matchesChecked("a.txt", timeLimit: .infinity) }
        #expect(throws: (any Error).self) { try mask.matchingNames(["a.txt", String(repeating: "a", count: 65_537)]) }
        #expect(!mask.matches(String(repeating: "a", count: 65_537)))
        let many = (0..<10_000).map { "file\($0).txt" }
        #expect(throws: (any Error).self) { try mask.matchingNames(many, timeLimit: 0.000_001) }
    }

    @Test
    func catastrophicRegexStopsCooperativelyAndBulkThrows() throws {
        let mask = try FileMask("/^(a+)+$/")
        let input = String(repeating: "a", count: 4_000) + "!"
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: (any Error).self) { try mask.matchesChecked(input, timeLimit: 0.005) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
        #expect(!mask.matches(input))
        #expect(throws: (any Error).self) { try mask.matchingNames(["a", input], timeLimit: 0.005) }
    }

}
