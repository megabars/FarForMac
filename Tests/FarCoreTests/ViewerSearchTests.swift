import Foundation
import Testing
@testable import FarCore

@Suite
struct ViewerSearchTests {
    @Test
    func literalCrossesPagesWithExactUnicodeByteRangesAndCase() throws {
        let prefix = String(repeating: "x", count: 65_534)
        let text = prefix + "🙂ПрИвЕт\nПривет"
        let document = try self.document(Data(text.utf8))
        let query = ViewerSearchQuery(pattern: "🙂привет")
        let result = try #require(try ViewerSearch.find(document: document, query: query, from: 0))
        #expect(result.byteRange == 65_534..<(65_534 + Int64("🙂ПрИвЕт".utf8.count)))
        #expect(try ViewerSearch.find(document: document,
            query: ViewerSearchQuery(pattern: query.pattern, caseSensitive: true), from: 0) == nil)
        #expect(try ViewerSearch.find(document: document, query: query, from: result.byteRange.lowerBound + 1) == nil)
    }

    @Test
    func backwardFindsLatestOverlappingLiteralAndCanCrossFromPageBoundary() throws {
        let document = try self.document(Data("ababa".utf8))
        let query = ViewerSearchQuery(pattern: "aba", caseSensitive: true)
        #expect(try ViewerSearch.find(document: document, query: query, from: 5, direction: .backward)?.byteRange == 2..<5)
        #expect(try ViewerSearch.find(document: document, query: query, from: 2, direction: .backward)?.byteRange == 0..<3)
        #expect(try ViewerSearch.find(document: document, query: query, from: 0, direction: .backward) == nil)
        let unicode = try self.document(Data("🙂🙂🙂".utf8))
        let pair = ViewerSearchQuery(pattern: "🙂🙂", caseSensitive: true)
        #expect(try ViewerSearch.find(document: unicode, query: pair, from: 1)?.byteRange == 4..<12)
        #expect(try ViewerSearch.find(document: unicode, query: pair, from: 4, direction: .backward)?.byteRange == 0..<8)
        let boundary = try self.document(Data((String(repeating: "x", count: 65_534) + "needle").utf8))
        #expect(try ViewerSearch.find(document: boundary, query: .init(pattern: "needle"),
                                     from: 65_535, direction: .backward)?.byteRange == 65_534..<65_540)
    }

    @Test
    func literalSearchHasNoLogicalLineLengthLimitAndReportsBoundedReads() throws {
        let source = ViewerSearchTestSource(Data((String(repeating: "a", count: 1_100_000) + "needle").utf8))
        let document = try ViewerDocument(source: source, encoding: .utf8)
        var progress = [Int64]()
        let found = try ViewerSearch.find(document: document, query: .init(pattern: "needle"), from: 0) { progress.append($0) }
        #expect(found?.byteRange == 1_100_000..<1_100_006)
        #expect(progress.count > 10)
        #expect(progress == progress.sorted())
        #expect(source.maximumRead <= 65_544)
    }

    @Test
    func legacyAndUTF16EncodingPreserveOriginalByteOffsets() throws {
        // windows-1251: "x Привет x"
        let legacy = try document(Data([0x78, 0x20, 0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x20, 0x78]), encoding: .windows1251)
        #expect(try ViewerSearch.find(document: legacy, query: .init(pattern: "привет"), from: 0)?.byteRange == 2..<8)
        let text = "x🙂Привет\nend"
        var bytes = Data([0xFF, 0xFE])
        for unit in text.utf16 { bytes.append(UInt8(truncatingIfNeeded: unit)); bytes.append(UInt8(unit >> 8)) }
        let utf16 = try document(bytes, encoding: .automatic)
        #expect(try ViewerSearch.find(document: utf16, query: .init(pattern: "🙂привет"), from: 0)?.byteRange == 4..<20)
        #expect(try ViewerSearch.find(document: utf16,
            query: .init(pattern: "^end$", mode: .regex), from: 0)?.byteRange == 22..<28)
    }

    @Test
    func regexUsesLogicalLinesAndZeroLengthMatchesProgressWithoutWrapping() throws {
        let document = try self.document(Data("🙂first\r\nsecond\rthird\nfourth\u{85}last".utf8))
        let query = ViewerSearchQuery(pattern: "^\\w+$", mode: .regex)
        let first = try #require(try ViewerSearch.find(document: document, query: query, from: 0))
        #expect(first.byteRange == 11..<17)
        let last = try #require(try ViewerSearch.find(document: document, query: query, from: document.size, direction: .backward))
        #expect(last.byteRange == (document.size - 4)..<document.size)
        let empty = ViewerSearchQuery(pattern: "^", mode: .regex)
        let zero = try #require(try ViewerSearch.find(document: document, query: empty, from: 0))
        #expect(zero.byteRange == 0..<0)
        let next = try #require(try ViewerSearch.find(document: document, query: empty, from: 1))
        #expect(next.byteRange == 11..<11)
        #expect(try ViewerSearch.find(document: document, query: empty,
                                     from: next.byteRange.lowerBound, direction: .backward)?.byteRange == 0..<0)
        let lookbehind = try self.document(Data("ababa".utf8))
        #expect(try ViewerSearch.find(document: lookbehind,
            query: .init(pattern: "(?<=ab)aba", mode: .regex), from: 1)?.byteRange == 2..<5)
        #expect(try ViewerSearch.find(document: lookbehind,
            query: .init(pattern: "aba", mode: .regex), from: 5, direction: .backward)?.byteRange == 2..<5)
    }

    @Test
    func longRegexLinesAreExplicitFailuresAndValidationIsUpfront() throws {
        let large = try document(Data(String(repeating: "a", count: ViewerSearch.maximumRegexLineBytes + 1).utf8))
        #expect(throws: ViewerSearchError.regexLineTooLong(offset: 0)) {
            try ViewerSearch.find(document: large, query: .init(pattern: "missing", mode: .regex), from: 0)
        }
        #expect(try ViewerSearch.find(document: large, query: .init(pattern: "missing", mode: .regex),
                                     from: 0, direction: .backward) == nil)
        #expect(throws: ViewerSearchError.emptyQuery) { try ViewerSearch.validate(.init(pattern: "")) }
        #expect(throws: ViewerSearchError.queryTooLong) { try ViewerSearch.validate(.init(pattern: String(repeating: "a", count: 4_097))) }
        #expect(throws: (any Error).self) { try ViewerSearch.validate(.init(pattern: "[", mode: .regex)) }
        for pattern in ["a\nb", #"a\nb"#, #"(?s)a.*b"#, #"\Afile"#] {
            #expect(throws: ViewerSearchError.unsupportedMultilineRegex) { try ViewerSearch.validate(.init(pattern: pattern, mode: .regex)) }
        }
        try ViewerSearch.validate(.init(pattern: #"a\s+b"#, mode: .regex))
        try ViewerSearch.validate(.init(pattern: #"\\n"#, mode: .regex))
    }

    @Test
    func forwardRegexSkipsEarlierLongAndExpensiveLines() throws {
        let prefix = String(repeating: "a", count: ViewerSearch.maximumRegexLineBytes + 10) + "\n"
        let long = try document(Data((prefix + "needle").utf8))
        #expect(try ViewerSearch.find(document: long, query: .init(pattern: "^needle$", mode: .regex),
            from: Int64(prefix.utf8.count))?.byteRange == Int64(prefix.utf8.count)..<long.size)
        let expensive = String(repeating: "a", count: 4_000) + "!\n"
        let hard = try document(Data((expensive + "needle").utf8))
        #expect(try ViewerSearch.find(document: hard,
            query: .init(pattern: "^(a+)+$|needle", mode: .regex), from: Int64(expensive.utf8.count))?.byteRange
            == Int64(expensive.utf8.count)..<hard.size)
    }

    @Test
    func expensiveRegexHasCooperativeDeadlineAndCancellation() throws {
        let document = try self.document(Data((String(repeating: "a", count: 4_000) + "!").utf8))
        let query = ViewerSearchQuery(pattern: "^(a+)+$", mode: .regex)
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: ViewerSearchError.regexDeadlineExceeded) {
            try ViewerSearch.find(document: document, query: query, from: 0)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
        let cancellation = ViewerCancellation()
        // The global pool is also running the parallel deadline tests. A
        // dedicated timer thread tests cancellation rather than pool starvation.
        let ready = DispatchSemaphore(value: 0), begin = DispatchSemaphore(value: 0)
        let timer = Thread {
            ready.signal(); begin.wait()
            Thread.sleep(forTimeInterval: 0.005); cancellation.cancel()
        }
        timer.qualityOfService = .userInteractive
        timer.start(); ready.wait(); begin.signal()
        #expect(throws: ViewerSearchError.cancelled) {
            try ViewerSearch.find(document: document, query: query, from: 0, cancellation: cancellation)
        }
    }

    @Test
    func cancellationStopsBeforeNextPageAndDoesNotReportNoMatch() throws {
        let source = ViewerSearchTestSource(Data(repeating: 0x61, count: 300_000))
        let document = try ViewerDocument(source: source, encoding: .utf8)
        let cancellation = ViewerCancellation()
        var progress = 0
        #expect(throws: ViewerSearchError.cancelled) {
            try ViewerSearch.find(document: document, query: .init(pattern: "missing"), from: 0,
                                  cancellation: cancellation) { _ in progress += 1; cancellation.cancel() }
        }
        #expect(progress == 1)
        let readCount = source.readCount
        #expect(throws: ViewerSearchError.cancelled) {
            try ViewerSearch.find(document: document, query: .init(pattern: "a"), from: 0, cancellation: cancellation)
        }
        #expect(source.readCount == readCount)
    }

    @Test
    func changedSourceIsReportedInsteadOfMissingResult() throws {
        let source = ViewerSearchTestSource(Data(repeating: 0x61, count: 200_000))
        let document = try ViewerDocument(source: source, encoding: .utf8)
        #expect(throws: ViewerError.changedFile) {
            try ViewerSearch.find(document: document, query: .init(pattern: "missing"), from: 0) { _ in
                source.markChanged()
            }
        }
    }

    @Test
    func hexSearchCrossesPagesIncludesBOMAndFindsOverlappingMatches() throws {
        var bytes = Data(repeating: 0, count: 65_535)
        bytes.append(contentsOf: [0xFF, 0x01, 0xFF, 0x01, 0xFF])
        let document = try self.document(bytes)
        let query = ViewerSearchQuery(pattern: "ff 01 ff", mode: .hex)
        #expect(try ViewerSearch.find(document: document, query: query, from: 0)?.byteRange == 65_535..<65_538)
        #expect(try ViewerSearch.find(document: document, query: query,
            from: document.size, direction: .backward)?.byteRange == 65_537..<65_540)
        let bom = try self.document(Data([0xEF, 0xBB, 0xBF, 0x61]))
        #expect(try ViewerSearch.find(document: bom, query: .init(pattern: "EFBBBF", mode: .hex), from: 0)?.byteRange == 0..<3)
        for pattern in ["f", "0x01", "GG", "  "] {
            #expect(throws: ViewerSearchError.invalidHex) { try ViewerSearch.validate(.init(pattern: pattern, mode: .hex)) }
        }
    }

    private func document(_ bytes: Data, encoding: ViewerEncoding = .utf8) throws -> ViewerDocument {
        try ViewerDocument(source: ViewerSearchTestSource(bytes), encoding: encoding)
    }
}

private final class ViewerSearchTestSource: ViewerByteSource, @unchecked Sendable {
    let data: Data
    let identity = UUID().uuidString
    var size: Int64 { Int64(data.count) }
    private let lock = NSLock()
    private var reads = 0
    private var largest = 0
    private var changed = false
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var maximumRead: Int { lock.lock(); defer { lock.unlock() }; return largest }
    init(_ data: Data) { self.data = data }
    func read(offset: Int64, count: Int) throws -> Data {
        lock.lock(); reads += 1; largest = max(largest, count); lock.unlock()
        guard offset >= 0, offset < size, count > 0 else { return Data() }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count))
    }
    func markChanged() { lock.lock(); changed = true; lock.unlock() }
    func verifyUnchanged() throws {
        lock.lock(); defer { lock.unlock() }
        if changed { throw ViewerError.changedFile }
    }
}
