import Foundation

/// Owns private sources until the normal operation queue finishes with them.
public final class SearchResultCopy: @unchecked Sendable {
    public let source: URL
    public let original: SearchMatch
    private let retainedWorkspace: AnyObject?
    init(source: URL, original: SearchMatch, workspace: AnyObject?) {
        self.source = source; self.original = original; retainedWorkspace = workspace
    }
}

public enum SearchResultCopies {
    public static let maximumBytes: Int64 = 256 * 1024 * 1024
    public static func prepare(_ matches: [SearchMatch], archivePasswords: [URL: String] = [:],
                               cancellation: TransferCancellation = TransferCancellation(),
                               progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> [SearchResultCopy] {
        guard !matches.isEmpty, matches.count <= 100 else {
            throw PanelSessionError("Для копирования выберите от 1 до 100 результатов.")
        }
        var copies: [SearchResultCopy] = [], bytes: Int64 = 0
        func reserve(_ count: Int64) throws {
            guard count >= 0, count <= maximumBytes - bytes else {
                throw PanelSessionError("Рабочие копии выбранных результатов превышают 256 МиБ. Выберите меньше объектов.")
            }
            bytes += count
        }
        for match in matches {
            if cancellation.isCancelled { throw ArchiveError.cancelled }
            switch match {
            case .saved: throw PanelSessionError("Восстановите сохранённый результат перед копированием.")
            case .local(let result):
                try result.verifyCurrent()
                copies.append(SearchResultCopy(source: result.url, original: match, workspace: nil))
            case .archive(let result):
                guard let snapshot = result.capturedArchiveSnapshot else { throw ArchiveError.changedArchive }
                try result.verifyArchiveCurrent(snapshot: snapshot)
                let entries = snapshot.entries.filter { $0.path == result.path || $0.path.hasPrefix(result.path + "/") }
                for entry in entries where !entry.isDirectory { try reserve(entry.size) }
                let workspace = try ArchiveReader.extract(snapshot, paths: [result.path], password: archivePasswords[snapshot.sourceURL],
                    cancellation: cancellation, onProgress: { value in
                        progress(NetworkProgress(path: match.displayPath, completedBytes: value.completedBytes, totalBytes: value.totalBytes))
                    })
                try result.verifyArchiveCurrent(snapshot: snapshot)
                copies.append(SearchResultCopy(source: try workspace.url(for: result.path), original: match, workspace: workspace))
            case .remote(let result, let provider):
                try result.verifyRemoteCurrent(provider: provider, cancellation: cancellation)
                guard let entry = result.remoteEntry, !entry.isSymbolicLink else { throw NetworkError.changedSource }
                let workspace = try RemoteWorkspace()
                let plan = try RemoteDirectoryTransfer.prepareDownload(provider: provider, entries: [entry], into: workspace.directory,
                    policy: .requireNew, cancellation: cancellation, progress: progress)
                try reserve(plan.totalBytes)
                _ = try RemoteDirectoryTransfer.copy(provider: provider, plan: plan, cancellation: cancellation, progress: progress)
                try result.verifyRemoteCurrent(provider: provider, cancellation: cancellation)
                copies.append(SearchResultCopy(source: workspace.directory.appendingPathComponent(entry.name), original: match, workspace: workspace))
            }
        }
        if cancellation.isCancelled { throw ArchiveError.cancelled }
        // Local references must still be the original files after slower providers finish.
        for copy in copies { if case .local(let result) = copy.original { try result.verifyCurrent() } }
        return copies
    }
}
