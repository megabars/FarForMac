import Foundation
import Testing
@testable import FarCore

@Suite
final class FilesTests {
    private let root: URL
    private let manager = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FarCoreTests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
    }

    deinit {
        try? manager.removeItem(at: root)
    }

    @Test
    func testListingHidesHiddenFilesAndKeepsDirectoriesFirstInBothDirections() throws {
        _ = try directory("z-folder")
        _ = try file("file10", text: "a")
        _ = try file("file2", text: "bb")
        _ = try file(".hidden")

        let ascending = try FileService.list(root, showHidden: false)
        #expect(ascending.map(\.name) == ["z-folder", "file2", "file10"])
        #expect(ascending.first?.id == ascending.first?.url.path)
        let descending = try FileService.list(root, showHidden: false, ascending: false)
        #expect(descending.map(\.name) == ["z-folder", "file10", "file2"])
        #expect(try FileService.list(root, showHidden: true).contains(where: { $0.name == ".hidden" }))
    }

    @Test
    func testListingSortsBySizeAndModificationDate() throws {
        let small = try file("small", text: "1")
        let large = try file("large", text: "12345")
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: large.path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: small.path)

        #expect(try FileService.list(root, showHidden: true, sort: .size).map(\.name) == ["small", "large"])
        #expect(try FileService.list(root, showHidden: true, sort: .size, ascending: false).map(\.size) == [5, 1])
        #expect(try FileService.list(root, showHidden: true, sort: .modified).map(\.name) == ["large", "small"])
        #expect(try FileService.list(root, showHidden: true, sort: .modified, ascending: false).map(\.name) == ["small", "large"])
    }

    @Test
    func testListingRecognizesDirectoryLinksAndRetainsDanglingLinks() throws {
        let folder = try directory("folder")
        let link = root.appendingPathComponent("folder-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: folder)
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "missing")

        let entries = try FileService.list(root, showHidden: true)
        let linked = try #require(entries.first(where: { $0.name == "folder-link" }))
        #expect(linked.isDirectory)
        #expect(linked.isSymbolicLink)
        #expect(linked.url.lastPathComponent == link.lastPathComponent)
        let dangling = try #require(entries.first(where: { $0.name == "dangling" }))
        #expect(dangling.isSymbolicLink)
        #expect(!(dangling.isDirectory))
    }

    @Test
    func testListingIncludesDatesPermissionsAndOwner() throws {
        let source = try file("private")
        try manager.setAttributes([.posixPermissions: 0o750], ofItemAtPath: source.path)
        let link = root.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: source)
        let values = try source.resourceValues(forKeys: [.creationDateKey, .contentAccessDateKey])
        let entries = try FileService.list(root, showHidden: true)
        let entry = try #require(entries.first(where: { $0.name == "private" }))
        #expect(entry.permissions == "-rwxr-x---")
        #expect(!entry.owner.isEmpty)
        #expect(entry.created == values.creationDate)
        #expect(entry.accessed == values.contentAccessDate)
        #expect(entries.first(where: { $0.name == "link" })?.permissions.hasPrefix("l") == true)
    }

    @Test
    func testCopyRecursesAndLeavesSourceUntouched() throws {
        let source = try directory("source")
        let nested = try directory("nested", in: source)
        _ = try file("hello.txt", text: "hello", in: nested)
        let target = try directory("target")

        try FileService.transfer([source], to: target, move: false)

        #expect(try String(contentsOf: target.appendingPathComponent("source/nested/hello.txt"), encoding: .utf8) == "hello")
        #expect(manager.fileExists(atPath: source.appendingPathComponent("nested/hello.txt").path))
    }

    @Test
    func testMoveRemovesSourceAndPreservesContents() throws {
        let source = try file("hello.txt", text: "hello")
        let target = try directory("target")
        try FileService.transfer([source], to: target, move: true)
        #expect(!(manager.fileExists(atPath: source.path)))
        #expect(try String(contentsOf: target.appendingPathComponent("hello.txt"), encoding: .utf8) == "hello")
    }

    @Test
    func testConflictPreflightDoesNotMoveEarlierItems() throws {
        let first = try file("first", text: "first")
        let second = try file("second", text: "second")
        let target = try directory("target")
        let existing = try file("second", text: "existing", in: target)

        #expect(throws: (any Error).self) { try FileService.transfer([first, second], to: target, move: true) }
        #expect(manager.fileExists(atPath: first.path))
        #expect(manager.fileExists(atPath: second.path))
        #expect(!(manager.fileExists(atPath: target.appendingPathComponent("first").path)))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
    }

    @Test
    func testMissingSourcePreflightDoesNotCopyEarlierItems() throws {
        let first = try file("first")
        let target = try directory("target")
        #expect(throws: (any Error).self) { try FileService.transfer([first, root.appendingPathComponent("missing")], to: target, move: false) }
        #expect(try manager.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test
    func testDuplicateDestinationNamesAreRejectedBeforeCopy() throws {
        let firstParent = try directory("a")
        let secondParent = try directory("b")
        let first = try file("same", in: firstParent)
        let second = try file("same", in: secondParent)
        let target = try directory("target")
        #expect(throws: (any Error).self) { try FileService.transfer([first, second], to: target, move: false) }
        #expect(try manager.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test(.enabled(if: FilesTests.caseInsensitiveTemporaryVolume))
    func testCaseInsensitiveDestinationConflictsAreRejectedBeforeCopy() throws {
        let firstParent = try directory("a")
        let secondParent = try directory("b")
        let first = try file("same", in: firstParent)
        let second = try file("SAME", in: secondParent)
        let target = try directory("target")
        #expect(throws: (any Error).self) { try FileService.transfer([first, second], to: target, move: false) }
        #expect(try manager.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test
    func testDanglingDestinationLinkIsNotOverwritten() throws {
        let source = try file("same")
        let target = try directory("target")
        let collision = target.appendingPathComponent("same")
        try manager.createSymbolicLink(atPath: collision.path, withDestinationPath: "missing")

        #expect(throws: (any Error).self) { try FileService.transfer([source], to: target, move: false) }
        #expect(try manager.destinationOfSymbolicLink(atPath: collision.path) == "missing")
    }

    @Test
    func testCopyAndMoveOperateOnLinksWithoutChangingTarget() throws {
        let folder = try directory("original")
        let original = try file("data", text: "keep", in: folder)
        let link = root.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: folder)
        let copied = try directory("copied")
        let moved = try directory("moved")

        try FileService.transfer([link], to: copied, move: false)
        try FileService.transfer([link], to: moved, move: true)

        #expect(try manager.destinationOfSymbolicLink(atPath: copied.appendingPathComponent("link").path) == folder.path)
        #expect(try manager.destinationOfSymbolicLink(atPath: moved.appendingPathComponent("link").path) == folder.path)
        #expect(!(manager.fileExists(atPath: link.path)))
        #expect(try String(contentsOf: original, encoding: .utf8) == "keep")
    }

    @Test
    func testDanglingSourceLinkCanBeCopied() throws {
        let source = root.appendingPathComponent("dangling")
        try manager.createSymbolicLink(atPath: source.path, withDestinationPath: "missing")
        let target = try directory("target")
        try FileService.transfer([source], to: target, move: false)
        #expect(try manager.destinationOfSymbolicLink(atPath: target.appendingPathComponent("dangling").path) == "missing")
    }

    @Test
    func testDirectoryCannotBeTransferredIntoItselfOrDescendantThroughLink() throws {
        let source = try directory("source")
        let nested = try directory("nested", in: source)
        let alias = root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: nested)

        for destination in [source, nested, alias] {
            #expect(throws: (any Error).self) { try FileService.transfer([source], to: destination, move: false) }
        }
        #expect(try manager.contentsOfDirectory(atPath: nested.path).isEmpty)
    }

    @Test(.enabled(if: FilesTests.caseInsensitiveTemporaryVolume))
    func testDirectoryCannotBeTransferredIntoItselfThroughCaseAlias() throws {
        let source = try directory("source")
        let nested = try directory("nested", in: source)
        let alias = root.appendingPathComponent("SOURCE/NESTED", isDirectory: true)
        #expect(throws: (any Error).self) { try FileService.transfer([source], to: alias, move: false) }
        #expect(try manager.contentsOfDirectory(atPath: nested.path).isEmpty)
    }

    @Test
    func testSameSourceAndDestinationThroughParentAliasIsRejected() throws {
        let parent = try directory("parent")
        let source = try file("source", in: parent)
        let alias = root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: parent)
        #expect(throws: (any Error).self) { try FileService.transfer([source], to: alias, move: true) }
        #expect(manager.fileExists(atPath: source.path))
    }

    @Test
    func testNestedSelectionsAndDuplicateSourceAliasesAreRejected() throws {
        let source = try directory("source")
        let child = try file("child", in: source)
        let destination = try directory("destination")
        let alias = root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: source)

        #expect(throws: (any Error).self) { try FileService.transfer([source, child], to: destination, move: true) }
        #expect(throws: (any Error).self) { try FileService.transfer([child, alias.appendingPathComponent("child")], to: destination, move: false) }
        #expect(manager.fileExists(atPath: child.path))
        #expect(try manager.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test
    func testCreateDirectoryValidatesNamesAndRefusesExistingLinks() throws {
        for name in ["", ".", "..", "a/b", "bad\0name"] {
            #expect(throws: (any Error).self) { try FileService.createDirectory(named: name, in: root) }
        }
        try FileService.createDirectory(named: "Новая папка", in: root)
        var isDirectory: ObjCBool = false
        #expect(manager.fileExists(atPath: root.appendingPathComponent("Новая папка").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(throws: (any Error).self) { try FileService.createDirectory(named: "Новая папка", in: root) }

        let dangling = root.appendingPathComponent("dangling")
        try manager.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing")
        #expect(throws: (any Error).self) { try FileService.createDirectory(named: "dangling", in: root) }
        #expect(try manager.destinationOfSymbolicLink(atPath: dangling.path) == "missing")
    }

    @Test
    func testRenamePreservesContentsAndRejectsInvalidNamesAndCollisions() throws {
        let source = try file("before", text: "content")
        for name in ["", ".", "..", "a/b"] {
            #expect(throws: (any Error).self) { try FileService.rename(source, to: name) }
        }
        let collision = root.appendingPathComponent("taken")
        try manager.createSymbolicLink(atPath: collision.path, withDestinationPath: "missing")
        #expect(throws: (any Error).self) { try FileService.rename(source, to: "taken") }
        #expect(throws: (any Error).self) { try FileService.rename(source, to: "before") }

        try FileService.rename(source, to: "after")
        #expect(!(manager.fileExists(atPath: source.path)))
        #expect(try String(contentsOf: root.appendingPathComponent("after"), encoding: .utf8) == "content")
        #expect(try manager.destinationOfSymbolicLink(atPath: collision.path) == "missing")
    }

    @Test
    func testUnavailableDirectoryAndNonFileURLsProduceLocalizedErrors() throws {
        #expect {
            try FileService.list(root.appendingPathComponent("missing"), showHidden: true)
        } throws: { error in
            error.localizedDescription.contains("Каталог")
        }
        #expect {
            try FileService.list(URL(string: "https://example.com")!, showHidden: true)
        } throws: { error in
            error.localizedDescription.contains("локальные файлы")
        }
    }

    private static var caseInsensitiveTemporaryVolume: Bool {
        (try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == false
    }

    private func directory(_ name: String, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? root).appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func file(_ name: String, text: String = "data", in parent: URL? = nil) throws -> URL {
        let url = (parent ?? root).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}
