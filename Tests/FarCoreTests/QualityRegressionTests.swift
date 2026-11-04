import Foundation
import Testing
@testable import FarCore

@Suite struct QualityRegressionTests {
    @Test func backgroundListingPreservesEntriesAndCustomSort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FarQuality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["file10", "file2", "Имя", ".hidden"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        let raw = try FileService.list(root, showHidden: false, sortResult: false)
        let normal = try FileService.list(root, showHidden: false)
        #expect(Set(raw.map(\.id)) == Set(normal.map(\.id)))
        #expect(FileService.sorted(raw, options: FileSortOptions()).map(\.id) == normal.map(\.id))
        #expect(!raw.contains { $0.name == ".hidden" })
        let options = FileSortOptions(sort: .size, ascending: false)
        #expect(FileService.sorted(raw, options: options).map(\.id) == FileService.sorted(normal, options: options).map(\.id))
        try FileManager.default.removeItem(at: root)
        #expect(throws: (any Error).self) { try FileService.list(root, showHidden: false, sortResult: false) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: root.appendingPathComponent("new-file"))
        #expect(try FileService.list(root, showHidden: false, sortResult: false).map(\.name) == ["new-file"])
    }
}
