import Foundation
import Darwin
import Testing
@testable import FarCore

struct TemporaryPanelListTests {
    @Test func portableJSONAndNULRoundTripLiteralNames() throws {
        let urls = ["/tmp/quote' \" $value", "/tmp/Юникод\nnewline", "/tmp/a://b"].map { URL(fileURLWithPath: $0).standardizedFileURL }
        for format in [TemporaryPanelList.Format.json, .nul] {
            let data = try TemporaryPanelList.encode(urls + [urls[0]], format: format)
            #expect(try TemporaryPanelList.decode(data, format: format, relativeTo: URL(fileURLWithPath: "/")) == urls)
        }
        #expect(throws: (any Error).self) { try TemporaryPanelList.encode(urls, format: .lines) }
    }
    @Test func relativeListsResolveAgainstListDirectoryWithoutEvaluation() throws {
        let base = URL(fileURLWithPath: "/tmp/list folder")
        let data = Data("\u{feff}a file\r\n../sibling\n$(touch bad)\n\n".utf8)
        let urls = try TemporaryPanelList.decode(data, format: .lines, relativeTo: base)
        #expect(urls.map(\.path) == ["/tmp/list folder/a file", "/tmp/sibling", "/tmp/list folder/$(touch bad)"])
        #expect(throws: (any Error).self) { try TemporaryPanelList.decode(Data("https://server/file".utf8), format: .lines, relativeTo: base) }
        #expect(throws: (any Error).self) { try TemporaryPanelList.decode(Data("bad\0name".utf8), format: .lines, relativeTo: base) }
        #expect(throws: (any Error).self) { try TemporaryPanelList.decode(Data("{\"version\":true,\"paths\":[]}".utf8), format: .json, relativeTo: base) }
        #expect(throws: (any Error).self) { try TemporaryPanelList.decode(Data(repeating: 0, count: TemporaryPanelList.maximumBytes + 1), format: .json, relativeTo: base) }
    }
    @Test func listReaderRejectsLinksAndSpecialFilesAndKeepsSnapshotProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = root.appendingPathComponent("item.txt"), list = root.appendingPathComponent("list.json")
        try Data("old".utf8).write(to: item)
        try TemporaryPanelList.encode([item]).write(to: list)
        let paths = try TemporaryPanelList.read(list, format: .json)
        let snapshot = try SearchResult.capture(#require(paths.first))
        try Data("replacement".utf8).write(to: item, options: .atomic)
        #expect(throws: (any Error).self) { try snapshot.verifyCurrent() }
        let link = root.appendingPathComponent("link"), fifo = root.appendingPathComponent("fifo")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: list)
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try TemporaryPanelList.read(link, format: .json) }
        #expect(throws: (any Error).self) { try TemporaryPanelList.read(fifo, format: .json) }
    }
}
