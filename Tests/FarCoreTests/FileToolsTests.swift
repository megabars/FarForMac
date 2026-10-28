import Foundation
import Testing
@testable import FarCore

@Suite
final class FileToolsTests {
    private let root: URL
    private let manager = FileManager.default
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FarTools-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? manager.removeItem(at: root) }
    private func file(_ name: String, content: String = "hello") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }
    private func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func renamePreviewIsLiteralAndDoesNotMutateUntilExecuted() throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let plan = try FileTools.renamePlan([a, b], template: "{n}-{name}.{ext}")
        #expect(plan.map(\.destination.lastPathComponent) == ["1-a.txt", "2-b.txt"])
        #expect(manager.fileExists(atPath: a.path))
        #expect(try FileTools.executeRename(plan) == 2)
        #expect(!manager.fileExists(atPath: a.path))
        #expect(try String(contentsOf: root.appendingPathComponent("1-a.txt"), encoding: .utf8) == "hello")
        let braces = try file("{n}.txt")
        #expect(try FileTools.renamePlan([braces], template: "{name}-new.{ext}").first?.destination.lastPathComponent == "{n}-new.txt")
    }

    @Test func renameRejectsCollisionsSourcesUnknownTokensAndInvalidNames() throws {
        let a = try file("a.txt"), b = try file("b.txt")
        #expect(throws: (any Error).self) { try FileTools.renamePlan([a, b], template: "same") }
        #expect(throws: (any Error).self) { try FileTools.renamePlan([a], template: "b.txt") }
        #expect(throws: (any Error).self) { try FileTools.renamePlan([a], template: "{name}.{ext}") }
        #expect(throws: (any Error).self) { try FileTools.renamePlan([a], template: "{unknown}") }
        #expect(throws: (any Error).self) { try FileTools.renamePlan([a], template: "../escape") }
        #expect(throws: (any Error).self) { try FileTools.renamePlan([a, a], template: "{n}") }
        #expect(try String(contentsOf: b, encoding: .utf8) == "hello")
    }

    @Test func reviewedRenameRejectsLateDestinationAndReplacedSource() throws {
        let a = try file("a")
        let plan = try FileTools.renamePlan([a], template: "renamed")
        let destination = try file("renamed", content: "keep")
        #expect(throws: (any Error).self) { try FileTools.executeRename(plan) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
        try manager.removeItem(at: destination)
        // Keep the old inode alive so a fresh allocation cannot reuse it.
        try manager.moveItem(at: a, to: root.appendingPathComponent("old-a"))
        _ = try file("a", content: "replacement")
        #expect(throws: (any Error).self) { try FileTools.executeRename(plan) }
        #expect(try String(contentsOf: a, encoding: .utf8) == "replacement")
    }

    @Test func permissionsValidateOctalAndNeverFollowSymbolicLinks() throws {
        #expect(try FileTools.parsePermissions("0755") == 0o755)
        #expect(try FileTools.parsePermissions("644") == 0o644)
        for invalid in ["888", "-1", "0x777", "17777", "77", " 644", "0644 "] {
            #expect(throws: (any Error).self) { try FileTools.parsePermissions(invalid) }
        }
        let target = try file("target")
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let link = root.appendingPathComponent("symlink")
        try FileTools.createLink(source: FileTools.metadata(target), at: link, symbolic: true)
        #expect(throws: (any Error).self) { try FileTools.setPermissions("777", for: FileTools.metadata(link)) }
        #expect(try FileTools.metadata(target).permissions == 0o600)
        try FileTools.setPermissions("640", for: FileTools.metadata(target))
        #expect(try FileTools.metadata(target).permissions == 0o640)
        try FileTools.setPermissions("000", for: FileTools.metadata(target))
        try FileTools.setPermissions("640", for: FileTools.metadata(target))
        #expect(try FileTools.metadata(target).permissions == 0o640)
        let old = try FileTools.metadata(target)
        try manager.moveItem(at: target, to: root.appendingPathComponent("old-target"))
        try manager.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("old-target"))
        #expect(throws: (any Error).self) { try FileTools.setPermissions("777", for: old) }
        #expect(try FileTools.metadata(root.appendingPathComponent("old-target")).permissions == 0o640)
    }

    @Test func linksAreExclusiveAndHardLinksRejectDirectories() throws {
        let target = try file("target")
        let hard = root.appendingPathComponent("hard")
        try FileTools.createLink(source: FileTools.metadata(target), at: hard, symbolic: false)
        try Data("shared".utf8).write(to: hard)
        #expect(try String(contentsOf: target, encoding: .utf8) == "shared")
        #expect(throws: (any Error).self) { try FileTools.createLink(source: FileTools.metadata(target), at: hard, symbolic: true) }
        let dir = try directory("dir")
        #expect(throws: (any Error).self) { try FileTools.createLink(source: FileTools.metadata(dir), at: root.appendingPathComponent("dir-hard"), symbolic: false) }
        let dangling = root.appendingPathComponent("dangling")
        try manager.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing")
        #expect(throws: (any Error).self) { try FileTools.createLink(source: FileTools.metadata(target), at: dangling, symbolic: true) }
    }

    @Test func sizeDoesNotFollowLinksAndReportsCancellation() throws {
        let folder = try directory("folder")
        try Data("123".utf8).write(to: folder.appendingPathComponent("child"))
        let outside = try file("outside", content: "123456789")
        try manager.createSymbolicLink(at: folder.appendingPathComponent("outside-link"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: folder.appendingPathComponent("loop"), withDestinationURL: folder)
        let result = try FileTools.directorySize(folder)
        #expect(result.bytes == 3)
        #expect(result.files == 1)
        #expect(result.symbolicLinks == 2)
        #expect(!result.isCancelled)
        let cancellation = FileToolCancellation(); cancellation.cancel()
        let stopped = try FileTools.directorySize(folder, cancellation: cancellation)
        #expect(stopped.isCancelled)
        #expect(stopped.bytes == 0)
        #expect(throws: (any Error).self) { try FileTools.directorySize(folder.appendingPathComponent("loop")) }
    }

    @Test func permanentDeleteDoesNotFollowLinksAndRejectsUnsafeSelections() throws {
        let folder = try directory("folder")
        let inside = folder.appendingPathComponent("inside")
        try Data("x".utf8).write(to: inside)
        let outside = try file("keep")
        try manager.createSymbolicLink(at: folder.appendingPathComponent("keep-link"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: folder.appendingPathComponent("loop"), withDestinationURL: folder)
        #expect(throws: (any Error).self) { try FileTools.snapshot([folder, inside]) }
        #expect(throws: (any Error).self) { try FileTools.snapshot([URL(fileURLWithPath: "/")]) }
        let snapshot = try FileTools.snapshot([folder])
        let cancellation = FileToolCancellation(); cancellation.cancel()
        #expect(throws: (any Error).self) { try FileTools.permanentlyDelete(snapshot, cancellation: cancellation) }
        #expect(manager.fileExists(atPath: inside.path))
        #expect(try FileTools.permanentlyDelete(snapshot) == 1)
        #expect(!manager.fileExists(atPath: folder.path))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "hello")
    }

    @Test func permanentDeleteRejectsReplacedSourceAndUnlinksDanglingLink() throws {
        let source = try file("selected")
        let snapshot = try FileTools.snapshot([source])
        try manager.moveItem(at: source, to: root.appendingPathComponent("original"))
        _ = try file("selected", content: "replacement")
        #expect(throws: (any Error).self) { try FileTools.permanentlyDelete(snapshot) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "replacement")
        let dangling = root.appendingPathComponent("dangling")
        try manager.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing")
        #expect(try FileTools.permanentlyDelete(FileTools.snapshot([dangling])) == 1)
        #expect(throws: (any Error).self) { try FileTools.metadata(dangling) }
    }
}
