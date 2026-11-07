import Foundation
import Testing
@testable import FarCore

@Suite struct FarLuaFilesystemTests {
    @Test func copyMoveAndDeleteUseRealFilesAndReportConflict() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let target = root.appendingPathComponent("target.txt")
        try Data("new".utf8).write(to: source)
        try Data("original".utf8).write(to: target)

        let conflict = try await call("win.CopyFile", [.string("source.txt"), .string("target.txt"), .bool(true)], in: root)
        #expect(conflict.first == .nilValue && conflict.count == 3)
        #expect(try Data(contentsOf: target) == Data("original".utf8))
        #expect(try await call("win.CopyFile", [.string("source.txt"), .string("target.txt")], in: root) == [.bool(true)])
        #expect(try Data(contentsOf: target) == Data("new".utf8))

        let noReplace = try await call("win.MoveFile", [.string("source.txt"), .string("target.txt")], in: root)
        #expect(noReplace.first == .nilValue)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try await call("win.RenameFile", [.string("source.txt"), .string("target.txt"), .string("r")], in: root) == [.bool(true)])
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try await call("win.DeleteFile", [.string("target.txt")], in: root) == [.bool(true)])
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func directoryFlagsAndFolderStatusDoNotRemoveContents() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await call("mf.testfolder", [.string("a")], in: root) == [.integer(2)])
        #expect(try await call("mf.testfolder", [.integer(4)], in: root) == [.integer(-2)])
        #expect(try await call("win.CreateDir", [.string("a/b"), .string("o")], in: root).first == .nilValue)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
        #expect(try await call("win.CreateDir", [.string("a/b")], in: root) == [.bool(true)])
        #expect(try await call("mf.testfolder", [.string("a")], in: root) == [.integer(1)])
        #expect(try await call("mf.testfolder", [.string("a/b")], in: root) == [.integer(0)])
        #expect(try await call("win.CreateDir", [.string("a/b"), .bool(true)], in: root) == [.bool(true)])
        #expect(try await call("win.CreateDir", [.string("a/b")], in: root) == [.nilValue, .string("directory already exists")])
        #expect(try await call("win.RemoveDir", [.string("a")], in: root).first == .nilValue)
        #expect(try await call("win.DeleteFile", [.string("a/b")], in: root).first == .nilValue)
        #expect(try await call("win.RemoveDir", [.string("a/b")], in: root) == [.bool(true)])
        #expect(try await call("win.RemoveDir", [.string("a")], in: root) == [.bool(true)])
    }

    @Test func fileInfoMatchesWildcardsAndRecursiveListingKeepsLinkBoundaries() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("contents", isDirectory: true)
        let nested = contents.appendingPathComponent("nested", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("a;[x].txt")
        try Data("hello".utf8).write(to: file)
        try Data("private".utf8).write(to: outside.appendingPathComponent("outside.txt"))
        let link = contents.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(try await call("mf.fexist", [.string("contents/nested/*;[x].TXT")], in: root) == [.bool(true)])
        #expect(try await call("mf.fexist", [.string("contents/nested/*.zip")], in: root) == [.bool(false)])
        #expect(try await call("mf.fattr", [.string("contents/nest?d")], in: root) == [.integer(16)])
        let info = try await call("win.GetFileInfo", [.string("contents/nested/*.txt")], in: root)
        guard case .table(let fields) = info.first else { Issue.record("Expected win.GetFileInfo fields"); return }
        #expect(fields["FileName"] == .string("a;[x].txt"))
        #expect(fields["FileSize"] == .integer(5))

        let list = try await call("far.GetDirList", [.string("contents")], in: root)
        guard case .array(let items) = list.first else { Issue.record("Expected recursive panel items"); return }
        let paths = items.compactMap { item -> String? in
            guard case .table(let fields) = item else { return nil }
            return fields["FileName"]?.string
        }
        // Foundation may spell the temp root as /var or /private/var.
        let anchor = "/" + root.lastPathComponent + "/" + contents.lastPathComponent + "/"
        let relative = paths.compactMap { path -> String? in
            guard path.hasPrefix("/"), let match = path.range(of: anchor) else { return nil }
            return String(path[match.upperBound...])
        }
        #expect(relative.count == paths.count)
        #expect(Set(relative) == Set(["nested", "nested/a;[x].txt", "link"]))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lua-fs-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func call(_ name: String, _ args: [FarLuaValue], in root: URL) async throws -> [FarLuaValue] {
        let result = try await FarLuaFilesystem.invoke(name, arguments: args, directory: root)
        return try #require(result)
    }
}
