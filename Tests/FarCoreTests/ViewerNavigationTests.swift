import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite struct ViewerNavigationTests {
    @Test func capturesOnlyRegularFilesInPanelOrderWithoutEnumeratingNeighbors() throws {
        let tree = try NavigationTree()
        let a = try tree.file("a", "alpha"), z = try tree.file("z", "last"), b = try tree.file("b", "beta")
        let fifo = tree.root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let navigation = try ViewerNavigation(urls: [z, tree.root, a, fifo, a], currentURL: a)
        #expect(navigation.urls == [z, a])
        #expect(navigation.currentIndex == 1)
        #expect(navigation.adjacentIndex(forward: true) == nil)
        #expect(navigation.adjacentIndex(forward: false) == 0)
        let moved = try navigation.moving(to: 0)
        #expect(moved.currentIndex == 0 && navigation.currentIndex == 1)
        #expect(try moved.source(at: 0).read(offset: 0, count: 20) == Data("last".utf8))
        #expect(!moved.urls.contains(b))
        #expect(throws: ViewerError.invalidRange) { try navigation.source(at: -1) }
        #expect(throws: ViewerError.invalidRange) { try navigation.moving(to: 99) }
        #expect(throws: ViewerError.notRegularFile) { try ViewerNavigation(urls: [z], currentURL: b) }
        #expect(throws: ViewerError.unsupportedURL) { try ViewerNavigation(urls: [URL(string: "https://example.org/a")!], currentURL: a) }
    }

    @Test func staleTargetMutationReplacementAndSymlinkRetargetAreRejected() throws {
        let tree = try NavigationTree()
        let a = try tree.file("a", "alpha"), b = try tree.file("b", "bravo")
        var navigation = try ViewerNavigation(urls: [a, b], currentURL: a)
        try Data("changed".utf8).write(to: b)
        #expect(throws: ViewerError.changedFile) { try navigation.source(at: 1) }
        #expect(navigation.currentIndex == 0)
        navigation = try ViewerNavigation(urls: [a, b], currentURL: a)
        try FileManager.default.removeItem(at: b)
        _ = try tree.file("b", "changed")
        #expect(throws: ViewerError.changedFile) { try navigation.source(at: 1) }
        let link = tree.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
        navigation = try ViewerNavigation(urls: [a, link], currentURL: a)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        #expect(throws: ViewerError.changedFile) { try navigation.source(at: 1) }
    }

    @Test func deletionSpecialReplacementAndCancellationLeaveNavigationUntouched() throws {
        let tree = try NavigationTree()
        let a = try tree.file("a", "alpha"), b = try tree.file("b", "bravo")
        let navigation = try ViewerNavigation(urls: [a, b], currentURL: a)
        let token = ViewerCancellation(); token.cancel()
        #expect(throws: ViewerError.cancelled) { try navigation.source(at: 1, cancellation: token) }
        try FileManager.default.removeItem(at: b)
        #expect(throws: (any Error).self) { try navigation.source(at: 1) }
        #expect(mkfifo(b.path, 0o600) == 0)
        #expect(throws: ViewerError.notRegularFile) { try navigation.source(at: 1) }
        #expect(navigation.currentIndex == 0)
        #expect(try navigation.source(at: 0).read(offset: 0, count: 20) == Data("alpha".utf8))
    }
}

private final class NavigationTree {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FarViewerNavigation-" + UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func file(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}
