import Foundation

/// F7 edits a temporary list; F8 removes the referenced objects through their providers.
public enum TemporaryResultDeletion {
    public struct Plan: @unchecked Sendable {
        let matches: [SearchMatch]
        let archives: [(ArchiveSnapshot, [SearchMatch])]
        let remotes: [(any RemoteProvider, RemoteTreePlan, [SearchMatch])]
        public var count: Int { matches.count }
        public var paths: [String] { matches.map(\.displayPath) }
        public var permanentFileCount: Int {
            remotes.reduce(0) { $0 + $1.1.fileCount } + archiveAffectedEntries.filter { !$0.isDirectory }.count
        }
        public var permanentDirectoryCount: Int {
            remotes.reduce(0) { $0 + $1.1.directoryCount } + archiveAffectedEntries.filter(\.isDirectory).count
        }
        private var archiveAffectedEntries: [ArchiveEntry] {
            archives.flatMap { snapshot, matches in
                let roots = matches.compactMap { match -> String? in if case .archive(let result) = match { return result.path }; return nil }
                return snapshot.entries.filter { entry in roots.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") } }
            }
        }
        public var reviewPaths: [String] {
            var result = matches.compactMap { match -> String? in if case .local = match { return match.displayPath }; return nil }
            for (snapshot, items) in archives {
                let roots = items.compactMap { item -> String? in if case .archive(let value) = item { return value.path }; return nil }
                result += snapshot.entries.filter { entry in roots.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") } }.map { snapshot.sourceURL.path + " !/" + $0.path }
            }
            for (provider, tree, _) in remotes { result += tree.entries.map { SearchLocation.remoteDisplay(provider.connection, $0.path) } }
            return result
        }
        public var hasPermanentDeletions: Bool { !archives.isEmpty || !remotes.isEmpty }
    }
    public struct Outcome: @unchecked Sendable {
        public var completedIDs: Set<String> = []
        public var updatedArchives: [ArchiveSnapshot] = []
        public var failure: String?
    }
    public static func prepare(_ matches: [SearchMatch], cancellation: TransferCancellation = TransferCancellation()) throws -> Plan {
        guard !matches.isEmpty else { throw PanelSessionError("Не выбраны объекты.") }
        var archives: [(ArchiveSnapshot, [SearchMatch])] = []
        var remoteGroups: [(any RemoteProvider, [SearchMatch])] = []
        var seen = Set<String>()
        let unique = matches.filter { seen.insert($0.id).inserted }
        for match in unique {
            try verify(match, cancellation)
            switch match {
            case .saved: throw PanelSessionError("Сначала восстановите источник результата.")
            case .local: break
            case .archive(let result):
                guard let snapshot = result.capturedArchiveSnapshot, !snapshot.isReadOnly else { throw ArchiveError.unsupportedFormat }
                if let index = archives.firstIndex(where: { $0.0.searchIdentity == snapshot.searchIdentity }) { archives[index].1.append(match) }
                else { archives.append((snapshot, [match])) }
            case .remote(_, let provider):
                if let index = remoteGroups.firstIndex(where: { $0.0 === provider }) { remoteGroups[index].1.append(match) }
                else { remoteGroups.append((provider, [match])) }
            }
        }
        let locals = unique.compactMap { match -> SearchResult? in if case .local(let value) = match { return value }; return nil }
        for (snapshot, _) in archives {
            let backingPath = SearchLocation.localKey(snapshot.sourceURL)
            guard !locals.contains(where: { local in
                backingPath == local.searchIdentityPath || (local.isDirectory && !local.isSymbolicLink && backingPath.hasPrefix(local.searchIdentityPath + "/"))
            }) else { throw PanelSessionError("Выбраны одновременно архив и его содержимое. Удалите их отдельными операциями.") }
        }
        let remotes = try remoteGroups.map { provider, items in
            let entries = items.compactMap { match -> RemoteEntry? in if case .remote(let result, _) = match { return result.remoteEntry }; return nil }
            let roots = entries.filter { entry in !entries.contains { parent in
                parent.path != entry.path && parent.isDirectory && !parent.isSymbolicLink && entry.path.hasPrefix(parent.path + "/")
            } }
            return (provider, try RemoteTreeOperations.prepareDelete(provider: provider, entries: roots, cancellation: cancellation), items)
        }
        return Plan(matches: unique, archives: archives, remotes: remotes)
    }
    public static func execute(_ plan: Plan, cancellation: TransferCancellation = TransferCancellation(),
                               trash: ([URL]) throws -> Void = FileService.trash,
                               progress: @escaping (NetworkProgress) -> Void = { _ in }) -> Outcome {
        var outcome = Outcome()
        do {
            // Revalidate the reviewed targets before starting any mutation.
            for match in plan.matches { try verify(match, cancellation) }
            let local = plan.matches.compactMap { match -> (SearchMatch, SearchResult)? in
                if case .local(let value) = match { return (match, value) }; return nil
            }.sorted { $0.1.url.pathComponents.count < $1.1.url.pathComponents.count }
            var removedDirectories: [String] = []
            for (match, item) in local {
                try check(cancellation)
                let path = item.searchIdentityPath
                if removedDirectories.contains(where: { path.hasPrefix($0 + "/") }) { outcome.completedIDs.insert(match.id); continue }
                try item.verifyCurrent()
                try trash([item.url]); outcome.completedIDs.insert(match.id)
                if item.isDirectory && !item.isSymbolicLink { removedDirectories.append(path) }
                progress(NetworkProgress(path: match.displayPath, completedBytes: 0, totalBytes: 0))
            }
            for (snapshot, items) in plan.archives {
                try check(cancellation)
                let paths = items.compactMap { match -> String? in if case .archive(let value) = match { return value.path }; return nil }
                let roots = paths.filter { path in !paths.contains { parent in parent != path && path.hasPrefix(parent + "/") } }
                let updated = try ArchiveWriter.update(snapshot, deletions: roots, cancellation: cancellation)
                outcome.updatedArchives.append(updated); outcome.completedIDs.formUnion(items.map(\.id))
            }
            for (provider, tree, items) in plan.remotes {
                try check(cancellation)
                do {
                    try RemoteTreeOperations.delete(provider: provider, plan: tree, cancellation: cancellation, progress: progress)
                    outcome.completedIDs.formUnion(items.map(\.id))
                } catch let error as RemoteTreeOperationError {
                    let deleted = Set(error.report.completed.map(\.source))
                    outcome.completedIDs.formUnion(items.compactMap { match in
                        if case .remote(let result, _) = match, deleted.contains(result.path) { return match.id }; return nil
                    })
                    throw error
                }
            }
        } catch { outcome.failure = error.localizedDescription }
        return outcome
    }
    private static func check(_ token: TransferCancellation) throws { if token.isCancelled { throw ViewerError.cancelled } }
    private static func verify(_ match: SearchMatch, _ token: TransferCancellation) throws {
        try check(token)
        switch match {
        case .local(let value): try value.verifyCurrent()
        case .archive(let value):
            guard let snapshot = value.capturedArchiveSnapshot else { throw ArchiveError.changedArchive }
            try value.verifyArchiveCurrent(snapshot: snapshot)
        case .remote(let value, let provider): try value.verifyRemoteCurrent(provider: provider, cancellation: token)
        case .saved: throw PanelSessionError("Сначала восстановите источник результата.")
        }
    }
}

