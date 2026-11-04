import Foundation
import Darwin

/// Captured panel order. No directory enumeration and no open descriptors are
/// retained. Only unchanged regular-file targets can be opened from this list.
public struct ViewerNavigation: Sendable {
    public let urls: [URL]
    public let currentIndex: Int
    private let identities: [String]

    public init(urls: [URL], currentURL: URL) throws {
        guard currentURL.isFileURL, urls.allSatisfy(\.isFileURL) else { throw ViewerError.unsupportedURL }
        var files: [URL] = [], snapshots: [String] = [], seen = Set<URL>()
        for item in urls {
            let url = item.standardizedFileURL
            guard seen.insert(url).inserted else { continue }
            var info = stat()
            guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            files.append(url)
            snapshots.append("\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)")
        }
        guard let index = files.firstIndex(of: currentURL.standardizedFileURL) else { throw ViewerError.notRegularFile }
        self.urls = files; identities = snapshots; currentIndex = index
    }

    private init(urls: [URL], identities: [String], currentIndex: Int) {
        self.urls = urls; self.identities = identities; self.currentIndex = currentIndex
    }

    public func adjacentIndex(forward: Bool) -> Int? {
        let index = currentIndex + (forward ? 1 : -1)
        return urls.indices.contains(index) ? index : nil
    }

    /// Does not alter the current index. Commit only after the first page has
    /// loaded and the caller has checked that its operation wasn't cancelled.
    public func source(at index: Int, cancellation: ViewerCancellation = ViewerCancellation()) throws -> LocalViewerSource {
        guard urls.indices.contains(index) else { throw ViewerError.invalidRange }
        guard !cancellation.isCancelled else { throw ViewerError.cancelled }
        let source = try LocalViewerSource(url: urls[index])
        guard source.identity == identities[index] else { throw ViewerError.changedFile }
        try source.verifyUnchanged()
        guard !cancellation.isCancelled else { throw ViewerError.cancelled }
        return source
    }

    public func moving(to index: Int) throws -> ViewerNavigation {
        guard urls.indices.contains(index) else { throw ViewerError.invalidRange }
        return ViewerNavigation(urls: urls, identities: identities, currentIndex: index)
    }
}
