import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
final class PanelInspectionTests {
    private let root: URL
    private let manager = FileManager.default
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FarInspection-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? manager.removeItem(at: root) }

    private func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func file(_ name: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func treeIsOneLevelLazyFiltersHiddenAndMarksLinksAsLeaves() throws {
        let parent = try directory("Папка 2")
        _ = try directory("Папка 10")
        _ = try directory(".hidden")
        _ = try directory("Папка 2/deeper")
        _ = try file("ordinary", data: Data("text".utf8))
        try manager.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: parent)
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("broken").path, withDestinationPath: "absent")
        let listing = try PanelInspection.treeChildren(root)
        #expect(Set(listing.entries.map(\.name)) == ["link", "Папка 2", "Папка 10"])
        #expect(listing.entries.filter { !$0.isSymbolicLink }.map(\.name) == ["Папка 2", "Папка 10"])
        #expect(listing.entries.first { $0.name == "link" }?.isSymbolicLink == true)
        #expect(listing.unreadable == 0)
        #expect(!listing.truncated)
        #expect(try PanelInspection.treeChildren(parent).entries.map(\.name) == ["deeper"])
        #expect(try PanelInspection.treeChildren(root, showHidden: true).entries.contains { $0.name == ".hidden" })
        let bounded = try PanelInspection.treeChildren(root, limit: 1)
        #expect(bounded.entries.count == 1)
        #expect(bounded.truncated)
        #expect(try PanelInspection.treeChildren(root, limit: 0).truncated)
    }

    @Test func metadataUsesFreshLstatAndPreservesDanglingLinkIdentity() throws {
        let target = try file("file", data: Data("abc".utf8))
        let first = try PanelInspection.information(directory: root, selected: target)
        #expect(first.item.bytes == 3)
        #expect(first.item.kind == "Файл")
        #expect(first.totalBytes != nil)
        #expect(first.freeBytes != nil)
        try Data("longer".utf8).write(to: target)
        #expect(try PanelInspection.information(directory: root, selected: target).item.bytes == 6)
        let link = root.appendingPathComponent("dangling")
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
        let info = try PanelInspection.information(directory: root, selected: link)
        #expect(info.item.kind == "Символическая ссылка")
        #expect(info.item.linkDestination == "missing")
        #expect(info.item.url == link)
        #expect(try PanelInspection.information(directory: root).item.kind == "Папка")
        try manager.removeItem(at: target)
        #expect(throws: (any Error).self) { try PanelInspection.information(directory: root, selected: target) }
    }

    @Test func previewIsBoundedForHugeFilesAndPreservesUTF16() throws {
        let large = try file("large", data: Data(repeating: 65, count: 1_000_000))
        let preview = try PanelInspection.preview(large)
        #expect(preview.text.count == PanelInspection.maximumPreviewBytes)
        #expect(preview.totalBytes == 1_000_000)
        #expect(preview.displayedBytes == 65_536)
        #expect(preview.isTruncated)
        #expect(!preview.isBinary)
        let text = "Привет 🙂\n"
        let encoded = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        let unicode = try PanelInspection.preview(file("unicode", data: encoded))
        #expect(unicode.text == text)
        #expect(unicode.encoding == .utf16LE)
        #expect(!unicode.isBinary)
        #expect(!unicode.isTruncated)
        let empty = try PanelInspection.preview(file("empty", data: Data()))
        #expect(empty.text.isEmpty)
        #expect(!empty.isTruncated)
    }

    @Test func binaryPreviewShowsHexAndSpecialSourcesNeverBlock() throws {
        let binary = try PanelInspection.preview(file("binary", data: Data(repeating: 1, count: 10_000)))
        #expect(binary.isBinary)
        #expect(binary.displayedBytes == 4096)
        #expect(binary.isTruncated)
        #expect(binary.text.hasPrefix("00000000  01 01"))
        let fifo = root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ViewerError.notRegularFile) { try PanelInspection.preview(fifo) }
        #expect(throws: ViewerError.notRegularFile) { try PanelInspection.preview(root) }
    }

    @Test func sizeCountsHiddenAndHardlinksButNeverTraversesLinkCycles() throws {
        let sub = try directory("sub")
        let original = try file("a", data: Data(repeating: 1, count: 5))
        _ = try file(".hidden", data: Data(repeating: 1, count: 7))
        try Data(repeating: 1, count: 11).write(to: sub.appendingPathComponent("b"))
        try manager.linkItem(at: original, to: root.appendingPathComponent("hardlink"))
        try manager.createSymbolicLink(at: sub.appendingPathComponent("cycle"), withDestinationURL: root)
        try manager.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
        let fifo = root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let result = try PanelInspection.directorySize(root)
        #expect(result.bytes == 28)
        #expect(result.files == 4)
        #expect(result.directories == 1)
        #expect(result.symbolicLinks == 2)
        #expect(result.unreadable == 0)
        #expect(!result.isPartial)
        #expect(throws: (any Error).self) { try PanelInspection.directorySize(root.appendingPathComponent("outside")) }
    }

    @Test func cancellationInterruptsTraversalAndReportsPartialTotals() throws {
        for index in 0..<256 { _ = try file("f\(index)", data: Data([1])) }
        let cancellation = FileToolCancellation()
        var callbacks = 0
        let result = try PanelInspection.directorySize(root, cancellation: cancellation) { value in
            callbacks += 1
            if value.files >= 128 { cancellation.cancel() }
        }
        #expect(result.isCancelled)
        #expect(result.isPartial)
        #expect(result.files == 128)
        #expect(result.bytes == 128)
        #expect(callbacks == 2)
        #expect(throws: ViewerError.cancelled) { try PanelInspection.directorySize(root, cancellation: cancellation) }
        #expect(throws: ViewerError.cancelled) { try PanelInspection.treeChildren(root, cancellation: cancellation) }
        #expect(throws: ViewerError.cancelled) { try PanelInspection.information(directory: root, cancellation: cancellation) }
        #expect(throws: ViewerError.cancelled) { try PanelInspection.preview(root, cancellation: cancellation) }
    }

    @Test func depthLimitProducesExplicitlyPartialSize() throws {
        var deepest = root
        for _ in 0...PanelInspection.maximumDirectoryDepth {
            deepest.appendPathComponent("d", isDirectory: true)
            try manager.createDirectory(at: deepest, withIntermediateDirectories: false)
        }
        try Data([1, 2, 3]).write(to: deepest.appendingPathComponent("too-deep"))
        let result = try PanelInspection.directorySize(root)
        #expect(result.isPartial)
        #expect(result.unreadable == 1)
        #expect(result.files == 0)
        #expect(result.directories == PanelInspection.maximumDirectoryDepth + 1)
    }
}
