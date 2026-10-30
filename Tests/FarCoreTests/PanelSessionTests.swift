import Foundation
import Testing
@testable import FarCore

@Suite struct PanelSessionTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func identicalNamesStaySeparateAndDuplicatePathsKeepOriginalIdentity() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for dir in [a,b] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let first = a.appendingPathComponent("имя.txt"), second = b.appendingPathComponent("имя.txt")
        try Data("one".utf8).write(to: first); try Data("two".utf8).write(to: second)
        let original = try SearchResult.capture(first)
        let result = try TemporaryPanelItems.merging([original], [SearchResult.capture(second), SearchResult.capture(first)])
        #expect(result.count == 2)
        try Data("changed".utf8).write(to: first, options: .atomic)
        let duplicate = try TemporaryPanelItems.merging(result, [SearchResult.capture(first)])
        #expect(throws: (any Error).self) { try duplicate[0].verifyCurrent() }
        try duplicate[1].verifyCurrent()
    }
    @Test func restartPreservesIdentityAndRejectsDeletedOrReplacedSources() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("before".utf8).write(to: file)
        let saved = PanelSession(directory: root.path, mode: .quickView, cursorID: file.path,
                                 filter: "file", temporaryItems: [try SearchResult.capture(file)], directoryFilter: "old")
        let restored = try PanelSession.decode(saved.encoded())
        #expect(restored.mode == .quickView && restored.filter == "file" && restored.directoryFilter == "old")
        try restored.temporaryItems![0].verifyCurrent()
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) { try restored.temporaryItems![0].verifyCurrent() }
        try Data("replacement".utf8).write(to: file)
        #expect(throws: (any Error).self) { try restored.temporaryItems![0].verifyCurrent() }
    }
    @Test func boundsAndSpecialFilesAreRejected() throws {
        #expect(throws: (any Error).self) { try PanelSession(directory: "relative").encoded() }
        #expect(throws: (any Error).self) { try PanelSession(directory: "/", filter: String(repeating: "x", count: 16_385)).encoded() }
        #expect(throws: (any Error).self) { try PanelSession.decode(Data(repeating: 0, count: 8 * 1024 * 1024 + 1)) }
        #expect(throws: (any Error).self) { try SearchResult.capture(URL(fileURLWithPath: "/dev/null")) }
    }
}
