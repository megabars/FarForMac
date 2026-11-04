import Foundation
import Testing
@testable import FarCore

@Suite struct ViewerTailTests {
    @Test func tailReachesEOFWithUTF8ScalarAndHexRowAlignment() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(("😀" + String(repeating: "a", count: 65_535)).utf8).write(to: url)
        let update = try #require(try ViewerTail.poll(url: url, previousIdentity: nil))
        let page = try update.document.page(at: update.offset)
        #expect(page.endOffset == update.document.size)
        let hexStart = update.offset / 16 * 16
        let data = try update.document.source.read(offset: hexStart, count: 65_536)
        #expect(hexStart + Int64(data.count) == update.document.size)
    }
    @Test func followsAppendTruncationAndReplacementUsingFreshBoundedSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("growing.log")
        try Data("first\n".utf8).write(to: url)
        let first = try #require(try ViewerTail.poll(url: url, previousIdentity: nil))
        #expect(try first.document.page(at: first.offset).text == "first\n")
        #expect(try ViewerTail.poll(url: url, previousIdentity: first.document.source.identity) == nil)
        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(repeating: "x", count: 100_000) + "\nlast🙂\n").utf8)); try handle.close()
        let next = try #require(try ViewerTail.poll(url: url, previousIdentity: first.document.source.identity))
        #expect(throws: ViewerError.changedFile) { try first.document.source.verifyUnchanged() }
        let tail = try next.document.page(at: next.offset)
        #expect(tail.text.hasSuffix("last🙂\n")); #expect(tail.text.utf8.count <= 65_536)
        try Data("short\n".utf8).write(to: url, options: .atomic)
        let replaced = try #require(try ViewerTail.poll(url: url, previousIdentity: next.document.source.identity))
        #expect(try replaced.document.page(at: replaced.offset).text == "short\n")
        let truncate = try FileHandle(forWritingTo: url); try truncate.truncate(atOffset: 0); try truncate.close()
        let empty = try #require(try ViewerTail.poll(url: url, previousIdentity: replaced.document.source.identity))
        #expect(empty.document.size == 0); #expect(try empty.document.page(at: 0).text.isEmpty)
    }

    @Test func tailRejectsUnboundedReadSizesAndPreservesUTF16() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try EditorDocument.encode(text: "🙂Ж\r\n", format: .init(encoding: .utf16LE, bom: true)).write(to: url)
        let update = try #require(try ViewerTail.poll(url: url, previousIdentity: nil, encoding: .automatic))
        #expect(update.document.encoding == .utf16LE)
        #expect(try update.document.page(at: update.offset).text == "🙂Ж\r\n")
        #expect(throws: ViewerError.invalidRange) { try ViewerTail.poll(url: url, previousIdentity: nil, pageSize: 65_537) }
        #expect(throws: ViewerError.invalidRange) { try ViewerTail.poll(url: url, previousIdentity: nil, pageSize: 0) }
    }
}
