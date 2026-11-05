import Foundation
import Testing
@testable import FarCore

@Suite struct ViewerDumpTests {
    @Test func dumpRetainsControlCellsAndIncludesBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF, 65, 13, 10, 9, 0, 127, 66])
        let document = try ViewerDocument(source: DumpSource(data), encoding: .utf8)
        let page = try document.dumpPage(at: 0, columns: 5)
        #expect(page.text == "�››A␍\n␊␉␀␡B")
        #expect(page.startOffset == 0 && page.endOffset == 10)
        #expect(!page.invalidSequences)
        #expect(page.byteOffset(forUTF16: 5) == 5) // synthetic row break
        #expect(page.byteOffset(forUTF16: 6) == 5)
        #expect(page.utf16Range(forByteRange: 5..<6) == NSRange(location: 6, length: 1))
        #expect(try document.page(at: 0).text == "A\r\n\t\0\u{7F}B")
        #expect(try document.source.read(offset: 0, count: data.count) == data)
    }

    @Test func utf8CellsAcrossRowsAndArbitraryPagesMapExactlyToBytes() throws {
        let document = try ViewerDocument(source: DumpSource(Data("a🙂Жz".utf8)), encoding: .utf8)
        let page = try document.dumpPage(at: 0, columns: 3)
        #expect(page.text == "a🙂›\n››Ж\n›z")
        #expect(!page.invalidSequences)
        #expect(page.byteOffset(forUTF16: 1) == 1)
        #expect(page.byteOffset(forUTF16: 2) == 1)
        #expect(page.byteOffset(forUTF16: 3) == 2)
        #expect(try document.dumpPage(at: 2, byteCount: 2).text == "››")
        #expect(try document.dumpPage(at: 4, byteCount: 2).text == "›Ж")
        #expect(try document.dumpPage(at: 6, byteCount: 1).text == "›")
        #expect(try document.dumpPage(at: document.size).text.isEmpty)
    }

    @Test func utf16HasTwoByteCellsAndSafeSurrogatePairs() throws {
        for encoding in [ViewerEncoding.utf16LE, .utf16BE] {
            let units: [UInt16] = [0xFEFF, 0x41, 0xD83D, 0xDE42, 0xA, 0xD800]
            let data = Data(units.flatMap { unit in
                let low = UInt8(truncatingIfNeeded: unit), high = UInt8(truncatingIfNeeded: unit >> 8)
                return encoding == .utf16LE ? [low, high] : [high, low]
            } + [0xFF])
            let document = try ViewerDocument(source: DumpSource(data), encoding: encoding)
            let page = try document.dumpPage(at: 0, columns: 3)
            #expect(page.text == "�A🙂\n›␊�\n�")
            #expect(page.invalidSequences)
            #expect(page.endOffset == 13)
            let smile = try document.dumpPage(at: 5, byteCount: 2)
            #expect(smile.startOffset == 4 && smile.endOffset == 6 && smile.text == "🙂")
            #expect(!smile.invalidSequences)
            #expect(try document.dumpPage(at: 7, byteCount: 2).text == "›")
            #expect(try document.dumpPage(at: 12, byteCount: 2).text == "�")
        }
    }

    @Test func legacyMappingInvalidBytesAndInertFormatting() throws {
        let russian = try ViewerDocument(source: DumpSource(Data([0xCF, 0xF0, 0x98, 0x0A])), encoding: .windows1251)
        let page = try russian.dumpPage(at: 0)
        #expect(page.text == "Пр�␊" && page.invalidSequences)
        let malformed = try ViewerDocument(source: DumpSource(Data([0xE2, 0x82])), encoding: .utf8)
        #expect(try malformed.dumpPage(at: 0).text == "��")
        #expect(try malformed.dumpPage(at: 0).invalidSequences)
        let format = try ViewerDocument(source: DumpSource(Data("x\u{2028}\u{202E}\u{200F}\u{061C}y".utf8)), encoding: .utf8)
        #expect(try format.dumpPage(at: 0).text == "x�››�››�››�›y")
    }

    @Test func dumpIsBoundedAndRechecksSnapshot() throws {
        let source = DumpSource(Data(repeating: 65, count: 200_000))
        let document = try ViewerDocument(source: source)
        let page = try document.dumpPage(at: 17, byteCount: Int.max)
        #expect(page.startOffset == 17 && page.endOffset == 65_553)
        #expect(throws: ViewerError.invalidRange) { try document.dumpPage(at: -1) }
        #expect(throws: ViewerError.invalidRange) { try document.dumpPage(at: 200_001) }
        #expect(throws: ViewerError.invalidRange) { try document.dumpPage(at: 0, columns: 0) }
        #expect(throws: ViewerError.invalidRange) { try document.dumpPage(at: 0, byteCount: 0) }
        source.changed = true
        #expect(throws: ViewerError.changedFile) { try document.dumpPage(at: 0) }
    }

    @Test func hexGroupsBytesAndUsesTheSelectedCodePage() throws {
        let data = Data([0x2E, 0x8F, 0xE0, 10, 65, 66, 67, 68, 69, 70, 71])
        let source = DumpSource(data)
        let document = try ViewerDocument(source: source, encoding: .dos866)
        let page = try document.hexPage(at: 1, bytesPerRow: 9)
        let lines = page.text.split(separator: "\n").map(String.init)
        #expect(page.startOffset == 1 && page.endOffset == 11)
        #expect(lines[0] == "0000000001: 8F E0 0A 41 42 43 44 45 │ 46  Пр␊ABCDEF")
        #expect(lines[1].hasPrefix("000000000A: 47"))
        let alternate = try ViewerDocument(source: source, encoding: .windows1251).hexPage(at: 1, bytesPerRow: 9)
        #expect(alternate.text != page.text)
        #expect(try document.source.read(offset: 0, count: data.count) == data)
        for offset in page.startOffset..<page.endOffset {
            let range = try #require(page.utf16Range(forByteRange: offset..<(offset + 1)))
            #expect(range.length == 2 && page.byteOffset(forUTF16: range.location) == offset)
        }
        let group = try #require(page.utf16Range(forByteRange: 9..<11))
        #expect(page.byteOffset(forUTF16: group.location) == 9)
        #expect(page.byteOffset(forUTF16: NSMaxRange(group) - 1) == 10)
        #expect(page.utf16Range(forByteRange: 11..<11)?.location == page.text.utf16.count)
    }

    @Test func hexPreservesUTF8ContinuationCellsAcrossRowsAndPageBoundaries() throws {
        let document = try ViewerDocument(source: DumpSource(Data("1234567🙂X".utf8)), encoding: .utf8)
        let page = try document.hexPage(at: 0, bytesPerRow: 8)
        let lines = page.text.split(separator: "\n").map(String.init)
        #expect(lines[0].hasSuffix("1234567🙂"))
        #expect(lines[1].hasSuffix("›››X    "))
        let smile = (page.text as NSString).range(of: "🙂")
        #expect(page.byteOffset(forUTF16: smile.location) == 7)
        #expect(page.byteOffset(forUTF16: smile.location + 1) == 7)
        let continuation = (page.text as NSString).range(of: "›")
        #expect(page.byteOffset(forUTF16: continuation.location) == 8)
        #expect(try document.hexPage(at: 9, byteCount: 2, bytesPerRow: 8).text.hasSuffix("››      "))
    }

    @Test func hexUTF16DecodesRowLocalPairsAndPadsIncompleteRows() throws {
        let data = Data([0xFF, 0x41, 0, 0x3D, 0xD8, 0x42, 0xDE, 0x0A, 0, 0xFF, 0x42, 0])
        let document = try ViewerDocument(source: DumpSource(data), encoding: .utf16LE)
        let page = try document.hexPage(at: 1, bytesPerRow: 9)
        let lines = page.text.split(separator: "\n").map(String.init)
        #expect(lines[0].hasSuffix("A🙂›␊�"))
        #expect(lines[1].hasSuffix("B    "))
        let smile = (page.text as NSString).range(of: "🙂")
        #expect(page.byteOffset(forUTF16: smile.location + 1) == 3)
        #expect(page.byteOffset(forUTF16: NSMaxRange(smile)) == 5)
    }

    @Test func hexWidthFollowsFARAdjustmentGridAndViewportBounds() {
        #expect(ViewerHexLayout.defaultBytesPerRow == 16)
        #expect(ViewerHexLayout.adjustedBytesPerRow(16, by: 1, columns: 170, encoding: .utf8) == 17)
        #expect(ViewerHexLayout.adjustedBytesPerRow(16, by: 16, columns: 170, encoding: .utf8) == 32)
        #expect(ViewerHexLayout.adjustedBytesPerRow(33, by: -16, columns: 170, encoding: .utf8) == 32)
        #expect(ViewerHexLayout.adjustedBytesPerRow(32, by: -16, columns: 170, encoding: .utf8) == 16)
        #expect(ViewerHexLayout.adjustedBytesPerRow(8, by: -1, columns: 40, encoding: .utf8) == 8)
        #expect(ViewerHexLayout.adjustedBytesPerRow(16, by: -16, columns: 40, encoding: .utf8) == 16)
        #expect(ViewerHexLayout.adjustedBytesPerRow(16, by: 1, columns: 78, encoding: .utf8) == 15)
        #expect(ViewerHexLayout.adjustedBytesPerRow(16, by: 1, columns: 78, encoding: .utf16LE) == 17)
    }

    @Test func hexPaddingAtMaximumFileOffsetClampsBeforeAddition() throws {
        let document = try ViewerDocument(source: HighOffsetSource(), encoding: .utf8)
        let page = try document.hexPage(at: Int64.max - 1)
        #expect(page.endOffset == Int64.max)
        #expect(page.text.hasPrefix("7FFFFFFFFFFFFFFE: 41"))
        #expect(page.byteOffset(forUTF16: page.text.utf16.count - 1) == Int64.max)
        #expect(page.utf16Range(forByteRange: Int64.max..<Int64.max)?.location == page.text.utf16.count)
    }
}

private struct HighOffsetSource: ViewerByteSource {
    let size = Int64.max
    let identity = "hex-large-sparse"
    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, count <= LocalViewerSource.maximumReadCount else { throw ViewerError.invalidRange }
        return Data(repeating: 0x41, count: min(count, Int(size - offset)))
    }
    func verifyUnchanged() throws {}
}

private final class DumpSource: ViewerByteSource, @unchecked Sendable {
    let data: Data
    var changed = false
    init(_ data: Data) { self.data = data }
    var size: Int64 { Int64(data.count) }
    var identity: String { "dump-memory" }
    func read(offset: Int64, count: Int) throws -> Data {
        try verifyUnchanged()
        guard count <= LocalViewerSource.maximumReadCount else { throw ViewerError.invalidRange }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count))
    }
    func verifyUnchanged() throws { if changed { throw ViewerError.changedFile } }
}
