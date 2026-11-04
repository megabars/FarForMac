import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
struct FileSearchTests {
    @Test
    func recursiveNamesUseGroupsUnicodeAndHiddenPolicy() throws {
        let tree = try SearchTree()
        try tree.file("nested/ОТЧЁТ.TXT", "Привет")
        try tree.file("nested/skip.txt", "skip")
        try tree.file(".hidden.txt", "hidden")
        try tree.file(".private/deep.txt", "hidden")
        try tree.file("plain.md", "text")
        var options = SearchOptions(roots: [tree.root])
        options.namePattern = "<text>|skip*"
        options.kinds = [.file]
        let first = collect(options, groups: ["text": "*.txt"])
        #expect(first.results.map(\.name) == ["ОТЧЁТ.TXT"])
        #expect(first.summary.errors == 0)
        #expect(first.results[0].url.path == tree.url("nested/ОТЧЁТ.TXT").path)
        options.includeHidden = true
        let second = collect(options, groups: ["text": "*.txt"])
        #expect(Set(second.results.map(\.name)) == ["ОТЧЁТ.TXT", ".hidden.txt", "deep.txt"])
        #expect(second.summary.matches == 3)
    }

    @Test
    func literalAndRegexContentHaveCaseAndLineInformation() throws {
        let tree = try SearchTree()
        try tree.file("message.txt", "первая строка\nПрИвЕт [мир].\nконец")
        var options = SearchOptions(roots: [tree.root])
        options.kinds = [.file]
        options.contentMode = .literal
        options.contentQuery = "привет [мир]."
        let literal = collect(options)
        #expect(literal.summary.errors == 0)
        #expect(literal.results.count == 1)
        #expect(literal.results.first?.lineNumber == 2)
        #expect(literal.results.first?.snippet?.contains("ПрИвЕт [мир].") == true)
        options.caseSensitive = true
        #expect(collect(options).summary.matches == 0)
        options.contentMode = .regex
        options.contentQuery = #"(?m)^ПрИвЕт\s+\[мир\]\."#
        #expect(collect(options).summary.matches == 1)
        options.contentQuery = "привет.*мир"
        #expect(collect(options).summary.matches == 0)
        options.caseSensitive = false
        #expect(collect(options).summary.matches == 1)
    }

    @Test
    func contentCrossesReadBlocksAndSnippetsRemainBounded() throws {
        let tree = try SearchTree()
        let prefix = String(repeating: "a", count: 65_532)
        try tree.file("long.txt", prefix + "🙂Привет-tail" + String(repeating: "z", count: 100_000))
        var options = SearchOptions(roots: [tree.root])
        options.contentMode = .literal
        options.contentQuery = "🙂Привет-tail"
        let found = collect(options)
        #expect(found.summary.errors == 0)
        #expect(found.results.count == 1)
        #expect(found.results.first?.lineNumber == 1)
        #expect((found.results.first?.snippet?.utf16.count ?? 0) <= 242)
        #expect(found.results.first?.snippet?.contains("🙂Привет-tail") == true)
    }

    @Test
    func literalSearchHandlesLargeUnicodeContentAndEscapesRegexSyntax() throws {
        let tree = try SearchTree()
        // Literal matching has bounded input and no user-supplied regex syntax.
        // A valid large file must not become a visible skip just because the
        // worker is descheduled during another test's expensive regex search.
        let query = "🙂[ПрИвЕт]+(tail).*"
        try tree.file("large.txt", String(repeating: "я", count: 1_000_000) + "\n" + query)
        var options = SearchOptions(roots: [tree.root])
        options.contentMode = .literal
        options.contentQuery = "🙂[привет]+(tail).*"
        let found = collect(options)
        #expect(found.issues.isEmpty)
        let result = try #require(found.results.first)
        #expect(result.lineNumber == 2)
        #expect(result.snippet?.contains(query) == true)
        options.contentQuery = "🙂[привет]+(tail).+"
        let absent = collect(options)
        #expect(absent.summary.matches == 0)
        #expect(absent.issues.isEmpty)
        let cancellation = SearchCancellation()
        let cancelled = SearchEngine.run(SearchRequest(options: options), cancellation: cancellation) { event in
            if case .progress(let progress) = event, progress.currentPath.hasSuffix("large.txt") {
                cancellation.cancel()
            }
        }
        #expect(cancelled.cancelled)
        #expect(cancelled.matches == 0)
        #expect(cancelled.errors == 0)
    }

    @Test
    func contentLineNumbersRecognizeUnicodeAndLegacyNewlines() throws {
        let tree = try SearchTree()
        var options = SearchOptions(roots: [tree.root])
        options.contentMode = .literal
        options.contentQuery = "needle"
        for (index, separator) in ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"].enumerated() {
            let name = "case\(index).txt"
            try tree.file(name, "🙂first\(separator)second\(separator)needle")
            options.roots = [tree.url(name)]
            let found = collect(options)
            #expect(found.summary.errors == 0)
            let result = try #require(found.results.first)
            #expect(result.lineNumber == 3)
            #expect(result.snippet?.rangeOfCharacter(from: .newlines) == nil)
        }
        try tree.file("mixed.txt", "🙂\r\none\rtwo\nthree\u{85}four\u{2028}five\u{2029}needle")
        options.roots = [tree.url("mixed.txt")]
        #expect(collect(options).results.first?.lineNumber == 7)
    }

    @Test
    func sizeAndModificationBoundsAreInclusiveAndRootsAreSelectable() throws {
        let tree = try SearchTree()
        try tree.file("one/a.txt", "12345")
        try tree.file("two/b.txt", "123456")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: tree.url("one/a.txt").path)
        var options = SearchOptions(roots: [tree.url("one")])
        options.kinds = [.file]
        options.minSize = 5; options.maxSize = 5
        options.modifiedAfter = modified; options.modifiedBefore = modified
        let found = collect(options)
        #expect(found.results.map(\.name) == ["a.txt"])
        #expect(found.results.first?.size == 5)
        options.modifiedAfter = modified.addingTimeInterval(1)
        options.modifiedBefore = nil
        #expect(collect(options).summary.matches == 0)
        options = SearchOptions(roots: [tree.url("one/a.txt"), tree.url("two/b.txt")])
        #expect(Set(collect(options).results.map(\.name)) == ["a.txt", "b.txt"])
        options.roots = [tree.url("one/a.txt"), tree.url("one/a.txt")]
        #expect(collect(options).summary.matches == 1)
    }

    @Test
    func typeFiltersAndSymlinkFollowingDoNotLoop() throws {
        let tree = try SearchTree()
        try tree.file("real/note.txt", "needle")
        try FileManager.default.createSymbolicLink(atPath: tree.url("alias").path, withDestinationPath: "real")
        try FileManager.default.createSymbolicLink(atPath: tree.url("file-link").path, withDestinationPath: "real/note.txt")
        try FileManager.default.createSymbolicLink(atPath: tree.url("real/loop").path, withDestinationPath: "..")
        var options = SearchOptions(roots: [tree.root])
        options.kinds = [.file]
        let regular = collect(options)
        #expect(regular.results.map(\.name) == ["note.txt"])
        #expect(regular.summary.errors == 0)
        options.kinds = [.symbolicLink]
        #expect(Set(collect(options).results.map(\.name)) == ["alias", "file-link", "loop"])
        options.kinds = [.directory]
        #expect(collect(options).results.map(\.name) == ["real"])
        options.followSymbolicLinks = true
        options.kinds = [.file, .symbolicLink]
        let followed = collect(options)
        #expect(followed.results.filter { $0.name == "note.txt" }.count == 1)
        #expect(followed.issues.contains { $0.message.contains("цикл") })
        #expect(followed.summary.scanned < 20)
        options = SearchOptions(roots: [tree.url("file-link")])
        options.contentMode = .literal; options.contentQuery = "needle"
        #expect(collect(options).summary.matches == 0)
        options.followSymbolicLinks = true
        let linkedContent = collect(options)
        #expect(linkedContent.summary.matches == 1)
        #expect(linkedContent.results.first?.isSymbolicLink == true)
        try #require(linkedContent.results.first).verifyCurrent()
    }

    @Test
    func overlappingRootsAndParentAliasesDoNotDuplicateResults() throws {
        let tree = try SearchTree()
        try tree.file("real/note.txt", "needle")
        try FileManager.default.createSymbolicLink(atPath: tree.url("alias").path, withDestinationPath: "real")
        var options = SearchOptions(roots: [tree.root, tree.url("real"), tree.url("alias"), tree.url("real/note.txt")])
        options.kinds = [.file]
        options.followSymbolicLinks = true
        let found = collect(options)
        #expect(found.summary.matches == 1)
        #expect(found.results.map(\.name) == ["note.txt"])
        #expect(found.summary.errors == 0)
        let tmpAlias = URL(fileURLWithPath: tree.root.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
        options.roots = [tree.root, tmpAlias]
        #expect(collect(options).summary.matches == 1)
    }

    @Test
    func cancellationAndResultLimitStopStreamingWork() throws {
        let tree = try SearchTree()
        for index in 0..<50 { try tree.file("f\(index).txt", "text") }
        var options = SearchOptions(roots: [tree.root])
        options.kinds = [.file]
        let cancellation = SearchCancellation()
        var delivered = 0
        var progressCount = 0
        let cancelled = SearchEngine.run(SearchRequest(options: options), cancellation: cancellation) { event in
            if case .progress = event { progressCount += 1 }
            if case .result = event {
                delivered += 1
                cancellation.cancel()
            }
        }
        #expect(cancelled.cancelled)
        #expect(delivered == 1)
        #expect(cancelled.scanned < 51)
        #expect(progressCount >= 2)
        options.maximumResults = 2
        let limited = collect(options)
        #expect(limited.summary.limitReached)
        #expect(limited.results.count == 2)
        #expect(limited.summary.scanned < 51)
        let alreadyCancelled = SearchCancellation()
        alreadyCancelled.cancel()
        let untouched = SearchEngine.run(SearchRequest(options: options), cancellation: alreadyCancelled) { _ in }
        #expect(untouched.cancelled)
        #expect(untouched.scanned == 0)
    }

    @Test
    func oversizeInvalidUTF8AndBinaryContentAreVisibleSkips() throws {
        let tree = try SearchTree()
        try tree.file("good.txt", "needle")
        try tree.file("large.txt", String(repeating: "x", count: 64) + "needle")
        try Data([0xFF, 0xFE, 0x61]).write(to: tree.url("invalid.txt"))
        try Data([0, 0x61]).write(to: tree.url("binary.txt"))
        var options = SearchOptions(roots: [tree.root])
        options.contentMode = .literal; options.contentQuery = "needle"
        options.maximumContentBytes = 16
        let found = collect(options)
        #expect(found.results.map(\.name) == ["good.txt"])
        #expect(found.summary.errors == 3)
        #expect(found.issues.count == 3)
        #expect(found.summary.summary.contains("частично"))
        #expect(found.issues.contains { $0.path == tree.url("large.txt").path && $0.message.contains("предел") })
        // Exact-cap content is complete; no unexamined suffix is treated as a non-match.
        options.roots = [tree.url("good.txt")]
        options.maximumContentBytes = 6
        #expect(collect(options).summary.matches == 1)
        options.maximumContentBytes = 5
        #expect(collect(options).summary.errors == 1)
    }

    @Test
    func missingAndDeniedRootsReportErrorsAlongsideOtherResults() throws {
        let tree = try SearchTree()
        try tree.file("allowed.txt", "yes")
        try tree.file("denied/hidden.txt", "no")
        let denied = tree.url("denied")
        #expect(chmod(denied.path, 0) == 0)
        defer { chmod(denied.path, 0o700) }
        let options = SearchOptions(roots: [tree.url("missing"), denied, tree.url("allowed.txt")])
        let found = collect(options)
        #expect(found.results.contains { $0.name == "allowed.txt" })
        #expect(found.issues.contains { $0.path == tree.url("missing").path })
        if getuid() != 0 { #expect(found.issues.contains { $0.path == denied.path }) }
        #expect(found.summary.errors == found.issues.count)
    }

    @Test
    func fifoAndRacingReplacementAreNeverReadAsRegularFiles() throws {
        let tree = try SearchTree()
        #expect(mkfifo(tree.url("pipe").path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(atPath: tree.url("pipe-link").path, withDestinationPath: "pipe")
        try tree.file("victim.txt", "needle")
        var options = SearchOptions(roots: [tree.root])
        options.followSymbolicLinks = true
        options.contentMode = .literal; options.contentQuery = "needle"
        var replaced = false
        var issues = [SearchIssue]()
        let start = ProcessInfo.processInfo.systemUptime
        let summary = SearchEngine.run(SearchRequest(options: options), cancellation: SearchCancellation()) { event in
            if case .progress(let progress) = event, progress.currentPath == tree.url("victim.txt").path, !replaced {
                replaced = true
                unlink(tree.url("victim.txt").path)
                _ = mkfifo(tree.url("victim.txt").path, 0o600)
            }
            if case .issue(let issue) = event { issues.append(issue) }
        }
        #expect(replaced)
        #expect(summary.matches == 0)
        #expect(issues.contains { $0.path == tree.url("victim.txt").path })
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test
    func hiddenFlagAndDepthLimitAreExplicit() throws {
        let tree = try SearchTree()
        try tree.file("flagged.txt", "text")
        #expect(chflags(tree.url("flagged.txt").path, UInt32(UF_HIDDEN)) == 0)
        var options = SearchOptions(roots: [tree.root])
        options.kinds = [.file]
        #expect(collect(options).summary.matches == 0)
        options.includeHidden = true
        #expect(collect(options).summary.matches == 1)
        var deep = tree.root
        for _ in 0..<130 {
            deep.appendPathComponent("d", isDirectory: true)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: false)
        }
        try Data("unvisited".utf8).write(to: deep.appendingPathComponent("bottom.txt"))
        let limited = collect(options)
        #expect(!limited.results.contains { $0.name == "bottom.txt" })
        #expect(limited.issues.contains { $0.message.contains("глубины") })
        #expect(limited.summary.errors == 1)
        #expect(limited.summary.scanned <= 131)
    }

    @Test
    func cancellationInterruptsExpensiveContentRegex() throws {
        let tree = try SearchTree()
        try tree.file("hard.txt", String(repeating: "a", count: 4_000) + "!")
        var options = SearchOptions(roots: [tree.root])
        options.contentMode = .regex; options.contentQuery = "^(a+)+$"
        let cancellation = SearchCancellation()
        // A dedicated cancellation thread avoids competing with concurrent regex
        // tests on the global pool. Start its delay only when the file is reached.
        let ready = DispatchSemaphore(value: 0), reachedFile = DispatchSemaphore(value: 0)
        let cancelThread = Thread {
            ready.signal()
            guard reachedFile.wait(timeout: .now() + 2) == .success else { return }
            Thread.sleep(forTimeInterval: 0.005)
            cancellation.cancel()
        }
        cancelThread.qualityOfService = .userInteractive
        cancelThread.start(); ready.wait()
        let start = ProcessInfo.processInfo.systemUptime
        let summary = SearchEngine.run(SearchRequest(options: options), cancellation: cancellation) { event in
            if case .progress(let progress) = event, progress.currentPath.hasSuffix("hard.txt") { reachedFile.signal() }
        }
        #expect(summary.cancelled)
        #expect(summary.matches == 0)
        #expect(summary.errors == 0)
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test
    func staleResultsRejectReplacementAndChangedLinkedContent() throws {
        let tree = try SearchTree()
        try tree.file("original.txt", "needle")
        try tree.file("replacement.txt", "needle")
        var options = SearchOptions(roots: [tree.url("original.txt")])
        let original = try #require(collect(options).results.first)
        try original.verifyCurrent()
        #expect(rename(tree.url("replacement.txt").path, tree.url("original.txt").path) == 0)
        #expect(throws: (any Error).self) { try original.verifyCurrent() }
        try FileManager.default.createSymbolicLink(atPath: tree.url("link").path, withDestinationPath: "original.txt")
        options.roots = [tree.url("link")]
        options.followSymbolicLinks = true
        options.contentMode = .literal; options.contentQuery = "needle"
        let linked = try #require(collect(options).results.first)
        try linked.verifyCurrent()
        try tree.file("original.txt", "changed content")
        #expect(throws: (any Error).self) { try linked.verifyCurrent() }
        try FileManager.default.removeItem(at: tree.url("link"))
        #expect(throws: (any Error).self) { try linked.verifyCurrent() }
    }

    @Test
    func catastrophicContentRegexHasCooperativeDeadline() throws {
        let tree = try SearchTree()
        try tree.file("hard.txt", String(repeating: "a", count: 4_000) + "!")
        var options = SearchOptions(roots: [tree.root])
        options.contentMode = .regex; options.contentQuery = "^(a+)+$"
        let start = ProcessInfo.processInfo.systemUptime
        let found = collect(options)
        #expect(found.summary.matches == 0)
        #expect(found.summary.errors == 1)
        #expect(found.issues.first?.message.contains("время") == true)
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test
    func validationIsUpfrontAndOptionsRoundTrip() throws {
        let tree = try SearchTree()
        var options = SearchOptions(roots: [tree.root])
        options.contentMode = .regex; options.contentQuery = "["
        #expect(throws: (any Error).self) { try SearchEngine.validate(SearchRequest(options: options)) }
        let invalid = collect(options)
        #expect(invalid.summary.scanned == 0)
        #expect(invalid.summary.errors == 1)
        options.contentMode = .none
        options.namePattern = "<unknown>"
        #expect(throws: (any Error).self) { try SearchEngine.validate(SearchRequest(options: options)) }
        options.namePattern = "*"
        options.minSize = 10; options.maxSize = 5
        #expect(throws: (any Error).self) { try SearchEngine.validate(SearchRequest(options: options)) }
        options.minSize = nil; options.maxSize = nil
        options.modifiedAfter = Date(timeIntervalSince1970: 10)
        options.modifiedBefore = Date(timeIntervalSince1970: 0)
        #expect(throws: (any Error).self) { try SearchEngine.validate(SearchRequest(options: options)) }
        options.modifiedAfter = nil; options.modifiedBefore = nil
        options.maximumContentBytes = 64 * 1_024 * 1_024 + 1
        #expect(throws: (any Error).self) { try SearchEngine.validate(SearchRequest(options: options)) }
        options.maximumContentBytes = 1_024
        options.kinds = [.file, .symbolicLink]
        options.contentMode = .literal; options.contentQuery = "Привет"
        options.includeHidden = true; options.followSymbolicLinks = true
        try SearchEngine.validate(SearchRequest(options: options))
        let restored = try JSONDecoder().decode(SearchOptions.self, from: JSONEncoder().encode(options))
        #expect(restored.roots == options.roots)
        #expect(restored.contentQuery == options.contentQuery)
        #expect(restored.contentMode == .literal)
        #expect(restored.kinds == options.kinds)
        #expect(restored.maximumContentBytes == 1_024)
        #expect(restored.followSymbolicLinks && restored.includeHidden)
    }

    @Test func contentSupportsExplicitEncodingsAndBOMWithoutBinaryFalsePositives() throws {
        let tree = try SearchTree()
        let cases: [(ViewerEncoding, String.Encoding, String)] = [
            (.utf8, .utf8, "Привет"), (.utf16LE, .utf16LittleEndian, "Привет🙂"),
            (.utf16BE, .utf16BigEndian, "Привет🙂"), (.windows1251, .windowsCP1251, "Привет"),
            (.windows1252, .windowsCP1252, "café"), (.latin1, .isoLatin1, "café")]
        for (encoding, foundation, needle) in cases {
            let url = tree.url(encoding.rawValue + ".txt")
            let text = String(repeating: "a", count: 32_763) + "\r\n" + needle + "\rfinal"
            try #require(text.data(using: foundation)).write(to: url)
            var options = SearchOptions(roots: [url]); options.contentMode = .literal
            options.contentEncoding = encoding; options.contentQuery = needle.lowercased()
            let found = collect(options)
            #expect(found.issues.isEmpty)
            #expect(found.results.first?.lineNumber == 2)
            #expect(found.results.first?.snippet?.contains(needle) == true)
            options.contentMode = .regex; options.contentQuery = "(?m)^" + needle
            #expect(collect(options).results.first?.lineNumber == 2)
        }
        let bom = tree.url("bom.txt")
        try (Data([0xFF, 0xFE]) + #require("one\r\nПривет".data(using: .utf16LittleEndian))).write(to: bom)
        var options = SearchOptions(roots: [bom]); options.contentMode = .literal
        options.contentEncoding = .automatic; options.contentQuery = "Привет"
        #expect(collect(options).results.first?.lineNumber == 2)
    }

    @Test func earlyLiteralMatchDoesNotHideInvalidTailAndOldOptionsStillDecode() throws {
        let tree = try SearchTree(), url = tree.url("invalid-tail.txt")
        try (Data("needle".utf8) + Data(repeating: 65, count: 70_000) + Data([255])).write(to: url)
        var options = SearchOptions(roots: [url]); options.contentMode = .literal; options.contentQuery = "needle"
        let found = collect(options)
        #expect(found.results.isEmpty); #expect(found.summary.errors == 1)
        let old = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(SearchOptions.self, from: old).contentEncoding == nil)
        options.contentEncoding = .windows1251
        #expect(try JSONDecoder().decode(SearchOptions.self, from: JSONEncoder().encode(options)).contentEncoding == .windows1251)
    }

    @Test func literalSearchStreamsBeyondOldSixtyFourMiBLimit() throws {
        let tree = try SearchTree(), url = tree.url("large.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let block = Data(repeating: 65, count: 1_048_576)
        for _ in 0..<65 { try handle.write(contentsOf: block) }
        try handle.write(contentsOf: Data("\r\nTAIL_NEEDLE".utf8)); try handle.close()
        var options = SearchOptions(roots: [url]); options.contentMode = .literal
        options.contentQuery = "TAIL_NEEDLE"; options.maximumContentBytes = 66 * 1_048_576
        let found = collect(options)
        #expect(found.issues.isEmpty)
        #expect(found.results.first?.lineNumber == 2)
        options.contentMode = .regex
        #expect(throws: (any Error).self) { try SearchEngine.validate(SearchRequest(options: options)) }
    }

    @Test func hexSearchFindsBinaryAcrossPagesRegardlessOfEncoding() throws {
        let tree = try SearchTree()
        var bytes = Data(repeating: 0x61, count: 65_535)
        bytes.append(contentsOf: [0x00, 0xFF, 0xFE, 0x41, 0x42]); bytes.append(Data(repeating: 0xFF, count: 70_000))
        try bytes.write(to: tree.url("binary"))
        var options = SearchOptions(roots: [tree.url("binary")]); options.contentMode = .hex
        options.contentQuery = "00 ff FE 41 42"
        for encoding in ViewerEncoding.allCases {
            options.contentEncoding = encoding; options.caseSensitive.toggle()
            let found = collect(options)
            #expect(found.issues.isEmpty); #expect(found.results.count == 1)
            #expect(found.results.first?.byteOffset == 65_535); #expect(found.results.first?.lineNumber == nil)
            #expect(found.results.first?.snippet == "0xFFFF: 00 FF FE 41 42")
            try found.results.first?.verifyCurrent()
        }
        options.contentQuery = "41 42 FF 00"
        #expect(collect(options).results.isEmpty)
    }

    @Test func hexSearchIncludesBOMAndFirstLastSingleBytes() throws {
        let tree = try SearchTree(); let file = tree.url("bom")
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: file)
        var options = SearchOptions(roots: [file]); options.contentMode = .hex
        for (query, offset) in [("FF FE", Int64(0)), ("ffFE", 0), ("FFFE 0041", 0), ("00", 2), ("41", 3)] {
            options.contentQuery = query
            let result = collect(options)
            #expect(result.issues.isEmpty); #expect(result.results.first?.byteOffset == offset)
        }
        try Data().write(to: file)
        #expect(collect(options).results.isEmpty)
    }

    @Test func hexValidationRejectsMalformedPairsBeforeTraversalAndPreservesLegacyOptions() throws {
        var options = SearchOptions(roots: [URL(fileURLWithPath: "/not-a-real-search-root")]); options.contentMode = .hex
        for query in ["", " \n\t", "A", "ABC", "414", "0x41", "GG", "??", "41,42", "４１", "41 4", String(repeating: "41 ", count: 1_367)] {
            options.contentQuery = query
            let found = collect(options)
            #expect(found.summary.scanned == 0); #expect(found.summary.errors == 1)
            #expect(found.issues.first?.message.contains("HEX") == true)
        }
        options.contentQuery = " 00ff\t41\n42 "; options.maximumContentBytes = 4_096 * 1_048_576
        try SearchEngine.validate(SearchRequest(options: options))
        let encoded = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(SearchOptions.self, from: encoded).contentMode == .hex)
        options.contentMode = .literal; options.contentQuery = "text"; options.contentEncoding = nil
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        object.removeValue(forKey: "contentEncoding")
        let legacy = try JSONDecoder().decode(SearchOptions.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.contentMode == .literal); #expect(legacy.contentEncoding == nil)
    }

    @Test func hexSearchFollowsOnlyExplicitLinksAndRejectsOversizeFiles() throws {
        let tree = try SearchTree(); try Data([0, 0xFF]).write(to: tree.url("target"))
        try FileManager.default.createSymbolicLink(at: tree.url("link"), withDestinationURL: tree.url("target"))
        var options = SearchOptions(roots: [tree.url("link")]); options.contentMode = .hex; options.contentQuery = "00 FF"
        #expect(collect(options).results.isEmpty)
        options.followSymbolicLinks = true
        #expect(collect(options).results.first?.byteOffset == 0)
        options.maximumContentBytes = 1
        let capped = collect(options)
        #expect(capped.results.isEmpty); #expect(capped.summary.errors == 1)
    }

    @Test func hexScannerBoundsReadsAndContinuesValidationAfterEarlyMatch() throws {
        let source = HexScannerSource(Data([0, 0xFF]) + Data(repeating: 0x61, count: 150_000))
        let result = try SearchContentScanner.scanBytes(source: source, query: [0, 0xFF], cancellation: SearchCancellation())
        #expect(result?.byteOffset == 0); #expect(source.reads.count == 4)
        #expect(source.reads.allSatisfy { $0.count <= 65_536 })
        #expect(source.reads[2].offset == 131_072)
        source.reads = []; source.failAfterOffset = 65_536
        #expect(throws: ViewerError.changedFile) {
            try SearchContentScanner.scanBytes(source: source, query: [0, 0xFF], cancellation: SearchCancellation())
        }
        source.failAfterOffset = nil; source.shortRead = true
        #expect(throws: ViewerError.changedFile) {
            try SearchContentScanner.scanBytes(source: source, query: [0, 0xFF], cancellation: SearchCancellation())
        }
    }

    @Test func hexScannerCancellationAndPeriodicPrefixStayBounded() throws {
        let source = HexScannerSource(Data(repeating: 0x41, count: 65_537) + Data([0x42]))
        let result = try SearchContentScanner.scanBytes(source: source, query: [0x41, 0x41, 0x41, 0x42], cancellation: SearchCancellation())
        #expect(result?.byteOffset == 65_534)
        let token = SearchCancellation(); source.onRead = { token.cancel() }
        #expect(throws: ViewerError.cancelled) {
            try SearchContentScanner.scanBytes(source: source, query: [0x41], cancellation: token)
        }
    }

    private func collect(_ options: SearchOptions, groups: [String: String] = [:])
        -> (results: [SearchResult], issues: [SearchIssue], summary: SearchSummary) {
        var results = [SearchResult]()
        var issues = [SearchIssue]()
        let summary = SearchEngine.run(SearchRequest(options: options, maskGroups: groups), cancellation: SearchCancellation()) { event in
            switch event {
            case .result(let result): results.append(result)
            case .archiveResult: Issue.record("Local-only search unexpectedly emitted an archive result")
            case .issue(let issue): issues.append(issue)
            case .progress: break
            }
        }
        return (results, issues, summary)
    }
}

private final class SearchTree {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FarSearchTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    func file(_ path: String, _ contents: String) throws {
        let destination = url(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: destination)
    }
}

private final class HexScannerSource: ViewerByteSource, @unchecked Sendable {
    let bytes: Data
    var size: Int64 { Int64(bytes.count) }
    var identity: String { "hex-fixture" }
    var reads: [(offset: Int64, count: Int)] = []
    var failAfterOffset: Int64?
    var shortRead = false
    var onRead: (() -> Void)?
    init(_ bytes: Data) { self.bytes = bytes }
    func verifyUnchanged() throws {}
    func read(offset: Int64, count: Int) throws -> Data {
        reads.append((offset, count)); onRead?()
        if let failAfterOffset, offset >= failAfterOffset { throw ViewerError.changedFile }
        let length = max(0, count - (shortRead ? 1 : 0))
        return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + length))
    }
}
