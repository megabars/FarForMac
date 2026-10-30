import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
struct FileViewerTests {
    @Test
    func utf8PagesAlignOffsetsAndMapSurrogatePairs() throws {
        let document = try ViewerDocument(source: ViewerMemorySource(Data("a🙂Жz".utf8)))
        let page = try document.page(at: 3, byteCount: 1)
        #expect(page.startOffset == 1)
        #expect(page.endOffset == 5)
        #expect(page.text == "🙂")
        #expect(!page.invalidSequences)
        #expect(page.byteOffset(forUTF16: 0) == 1)
        #expect(page.byteOffset(forUTF16: 1) == 1)
        #expect(page.byteOffset(forUTF16: 2) == 5)
        #expect(page.utf16Range(forByteRange: 2..<3) == NSRange(location: 0, length: 2))
        #expect(page.utf16Range(forByteRange: 5..<5) == NSRange(location: 2, length: 0))
        #expect(page.utf16Range(forByteRange: 0..<1) == nil)
        #expect(try document.page(at: document.size).text.isEmpty)
        var offset: Int64 = 0, combined = ""
        while offset < document.size {
            let block = try document.page(at: offset, byteCount: 2)
            combined += block.text; offset = block.endOffset
        }
        #expect(combined == "a🙂Жz")
    }

    @Test
    func utf16BOMAndUnalignedOffsetsPreserveScalars() throws {
        for encoding in [ViewerEncoding.utf16LE, .utf16BE] {
            let payload = utf16Bytes("a🙂Жz", encoding: encoding, bom: true)
            let document = try ViewerDocument(source: ViewerMemorySource(payload))
            #expect(document.encoding == encoding)
            #expect(document.bomLength == 2)
            #expect(try document.page(at: 0).text == "a🙂Жz")
            for offset: Int64 in 4...7 {
                let page = try document.page(at: offset, byteCount: 1)
                #expect(page.startOffset == 4)
                #expect(page.endOffset == 8)
                #expect(page.text == "🙂")
            }
            #expect(try document.page(at: document.size).text.isEmpty)
        }
        let utf8 = try ViewerDocument(source: ViewerMemorySource(Data([0xEF, 0xBB, 0xBF]) + Data("hello".utf8)))
        #expect(utf8.encoding == .utf8)
        #expect(utf8.bomLength == 3)
        #expect(try utf8.page(at: 1).text == "hello")
    }

    @Test
    func invalidAndTruncatedSequencesAreFlaggedAndRemainReadOnly() throws {
        let malformed = Data([0x61, 0xC0, 0xAF, 0xF0, 0x9F, 0x62, 0xED, 0xA0, 0x80, 0xE2])
        let source = ViewerMemorySource(malformed)
        let document = try ViewerDocument(source: source, encoding: .utf8)
        let page = try document.page(at: 0)
        #expect(page.invalidSequences)
        #expect(page.text.hasPrefix("a��"))
        #expect(page.text.hasSuffix("�"))
        #expect(try source.read(offset: 0, count: malformed.count) == malformed)
        let utf16 = try ViewerDocument(source: ViewerMemorySource(Data([0x00, 0xD8, 0x61, 0x00, 0xFF])), encoding: .utf16LE)
        let decoded = try utf16.page(at: 0)
        #expect(decoded.text == "�a�")
        #expect(decoded.invalidSequences)
        #expect(decoded.endOffset == 5)
        #expect(try utf16.page(at: 5).text.isEmpty)
    }

    @Test
    func selectedLegacyEncodingsUseStableMaps() throws {
        let russian = try ViewerDocument(source: ViewerMemorySource(Data([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x20, 0xA8, 0xB8])), encoding: .windows1251)
        #expect(try russian.page(at: 0).text == "Привет Ёё")
        let western = try ViewerDocument(source: ViewerMemorySource(Data([0x80, 0x93, 0xE9, 0x94])), encoding: .windows1252)
        #expect(try western.page(at: 0).text == "€“é”")
        let latin = try ViewerDocument(source: ViewerMemorySource(Data([0x80, 0xA0, 0xE9])), encoding: .latin1)
        #expect(try latin.page(at: 0).text.unicodeScalars.map(\.value) == [0x80, 0xA0, 0xE9])
        let undefined = try ViewerDocument(source: ViewerMemorySource(Data([0x98])), encoding: .windows1251)
        #expect(try undefined.page(at: 0).invalidSequences)
        let automatic = try ViewerDocument(source: ViewerMemorySource(Data([0x80, 0xE9])))
        #expect(automatic.encoding == .windows1252)
        #expect(try automatic.page(at: 0).text == "€é")
    }

    @Test
    func automaticHandlesEmptyAndBOMlessUTF16() throws {
        let empty = try ViewerDocument(source: ViewerMemorySource(Data()))
        #expect(empty.encoding == .utf8)
        #expect(try empty.page(at: 0).text.isEmpty)
        for encoding in [ViewerEncoding.utf16LE, .utf16BE] {
            let document = try ViewerDocument(source: ViewerMemorySource(utf16Bytes("Hello World", encoding: encoding)))
            #expect(document.encoding == encoding)
            #expect(try document.page(at: 0).text == "Hello World")
        }
    }

    @Test
    func lineNavigationRecognizesEveryNewlineAndCRLF() throws {
        for encoding in [ViewerEncoding.utf8, .utf16LE, .utf16BE] {
            let text = "🙂\r\none\rtwo\nthree\u{85}four\u{2028}five\u{2029}last\n"
            let data = encoding == .utf8 ? Data(text.utf8) : utf16Bytes(text, encoding: encoding, bom: true)
            let document = try ViewerDocument(source: ViewerMemorySource(data), encoding: encoding)
            for line: Int64 in 1...8 {
                let offset = try document.offset(ofLine: line)
                #expect(try document.lineNumber(at: offset) == line)
            }
            #expect(try document.offset(ofLine: 8) == document.size)
            #expect(throws: ViewerError.lineNotFound) { try document.offset(ofLine: 9) }
            #expect(throws: ViewerError.invalidRange) { try document.offset(ofLine: 0) }
        }
    }

    @Test
    func CRLFCrossesPagesAndCancellationStopsLinearScans() throws {
        let text = String(repeating: "a", count: 65_535) + "\r\nlast"
        let document = try ViewerDocument(source: ViewerMemorySource(Data(text.utf8)))
        #expect(try document.offset(ofLine: 2) == 65_537)
        #expect(try document.lineNumber(at: 65_536) == 1)
        #expect(try document.lineNumber(at: 65_537) == 2)
        let cancellation = ViewerCancellation()
        var progress = [Int64]()
        #expect(throws: ViewerError.cancelled) {
            try document.offset(ofLine: 3, cancellation: cancellation) { value in
                progress.append(value); cancellation.cancel()
            }
        }
        #expect(!progress.isEmpty)
        #expect(throws: ViewerError.cancelled) { try document.offset(ofLine: 1, cancellation: cancellation) }
        #expect(throws: ViewerError.cancelled) { try document.lineNumber(at: 0, cancellation: cancellation) }
    }

    @Test
    func localSnapshotRejectsMutationReplacementAndSymlinkRetarget() throws {
        let tree = try ViewerTemporaryTree()
        let file = tree.root.appendingPathComponent("source")
        try Data("first".utf8).write(to: file)
        let link = tree.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let source = try LocalViewerSource(url: link)
        #expect(source.url == file)
        #expect(try source.read(offset: 0, count: 5) == Data("first".utf8))
        try Data("changed".utf8).write(to: file)
        #expect(throws: ViewerError.changedFile) { try source.read(offset: 0, count: 5) }
        let fresh = try LocalViewerSource(url: file)
        let replacement = tree.root.appendingPathComponent("replacement")
        try Data("changed".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        #expect(throws: ViewerError.changedFile) { try fresh.verifyUnchanged() }
        let linked = try LocalViewerSource(url: link)
        let other = tree.root.appendingPathComponent("other")
        try Data("other".utf8).write(to: other)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(throws: ViewerError.changedFile) { try linked.verifyUnchanged() }
    }

    @Test
    func rejectsSpecialFilesAndBoundsLargeSparseReads() throws {
        let tree = try ViewerTemporaryTree()
        let fifo = tree.root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ViewerError.notRegularFile) { try LocalViewerSource(url: fifo) }
        #expect(throws: ViewerError.notRegularFile) { try LocalViewerSource(url: tree.root) }
        let file = tree.root.appendingPathComponent("sparse")
        let fd = open(file.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        let offset: Int64 = 4_294_967_296 + 21
        #expect(ftruncate(fd, off_t(offset + 4)) == 0)
        let payload = Array("tail".utf8)
        let written = payload.withUnsafeBytes { pwrite(fd, $0.baseAddress, payload.count, off_t(offset)) }
        #expect(written == 4)
        let source = try LocalViewerSource(url: file)
        #expect(source.size == offset + 4)
        let document = try ViewerDocument(source: source, encoding: .utf8)
        let page = try document.page(at: offset)
        #expect(page.text == "tail")
        #expect(page.startOffset == offset)
        #expect(page.endOffset == offset + 4)
        #expect(throws: ViewerError.invalidRange) { try source.read(offset: 0, count: 100_000) }
        #expect(throws: ViewerError.invalidRange) { try document.page(at: -1) }
        #expect(throws: ViewerError.invalidRange) { try document.page(at: offset + 5) }
    }

    @Test
    func allBoundariesInFullUnicodePageMapToOriginalBytes() throws {
        let text = String(repeating: "a🙂Ж", count: 9_000)
        let document = try ViewerDocument(source: ViewerMemorySource(Data(text.utf8)))
        let page = try document.page(at: 0)
        let units = Array(page.text.utf16)
        // Exercise every boundary just as streaming search does. This catches
        // mapping regressions on full pages, including interior surrogate units.
        for index in 0...units.count {
            let group = index / 4, within = index % 4
            let expected = Int64(group * 7 + [0, 1, 1, 5][within])
            #expect(page.byteOffset(forUTF16: index) == expected)
        }
        #expect(page.endOffset == 63_000)
    }

    @Test
    func protocolSupportsIndependentProvidersAndCapsPages() throws {
        let document = try ViewerDocument(source: ViewerMemorySource(Data(repeating: 65, count: 200_000)))
        let page = try document.page(at: 17, byteCount: Int.max)
        #expect(page.text.count == 65_536)
        #expect(page.endOffset - page.startOffset == 65_536)
    }

    private func utf16Bytes(_ text: String, encoding: ViewerEncoding, bom: Bool = false) -> Data {
        var bytes: [UInt8] = bom ? (encoding == .utf16LE ? [0xFF, 0xFE] : [0xFE, 0xFF]) : []
        for unit in text.utf16 {
            let low = UInt8(truncatingIfNeeded: unit), high = UInt8(truncatingIfNeeded: unit >> 8)
            bytes += encoding == .utf16LE ? [low, high] : [high, low]
        }
        return Data(bytes)
    }
}

private struct ViewerMemorySource: ViewerByteSource {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    var size: Int64 { Int64(bytes.count) }
    var identity: String { "test-memory" }
    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset <= size, count >= 0, count <= LocalViewerSource.maximumReadCount else { throw ViewerError.invalidRange }
        return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + count))
    }
    func verifyUnchanged() throws {}
}

private final class ViewerTemporaryTree {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FarViewerTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}
