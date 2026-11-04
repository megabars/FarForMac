import Foundation
import FarCore

/// A search is tied to the captured provider, independently of later panel navigation.
/// Credentials remain owned by that provider and are never persisted as search settings.
enum ProviderSearchSource: @unchecked Sendable {
    case archive(ArchiveSnapshot, prefix: String)
    case remote(any RemoteProvider, root: String)

    var caption: String {
        switch self {
        case .archive(let snapshot, let prefix): return ArchiveNavigationFrame(snapshot: snapshot).displayPath + " !/" + prefix
        case .remote(let provider, let root): return provider.connection.displayName + " · " + root
        }
    }
    var supportsArchiveTraversal: Bool {
        if case .archive = self { return true }
        return false
    }
    var canEdit: Bool {
        if case .archive(let snapshot, _) = self { return !snapshot.isReadOnly }
        return true
    }
    func run(_ request: SearchRequest, password: String?, cancellation: ProviderSearchCancellation,
             onEvent: @escaping (ProviderSearchEvent) -> Void) -> SearchSummary {
        switch self {
        case .archive(let snapshot, let prefix):
            return ProviderSearchEngine.runArchive(snapshot, prefix: prefix, request: request, password: password,
                                                   cancellation: cancellation, onEvent: onEvent)
        case .remote(let provider, let root):
            return ProviderSearchEngine.runRemote(provider: provider, root: root, request: request,
                                                  cancellation: cancellation, onEvent: onEvent)
        }
    }
}

struct SearchDisplayRow {
    let path: String
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modified: Date?
    let snippet: String?
    let lineNumber: Int?
    init(_ result: SearchResult) {
        path = result.url.path; name = result.name; isDirectory = result.isDirectory; isSymbolicLink = result.isSymbolicLink
        size = result.size; modified = result.modified; snippet = result.snippet; lineNumber = result.lineNumber
    }
    init(_ result: ProviderSearchResult) {
        path = result.archiveDisplayPath.map { $0 + " !/" + result.path } ?? result.path; name = result.name; isDirectory = result.isDirectory; isSymbolicLink = result.isSymbolicLink
        size = result.size; modified = result.modified; snippet = result.snippet; lineNumber = result.lineNumber
    }
}

extension SearchLocation {
    /// Identity is tied to the captured provider, never its editable display name.
    var searchSourceID: String { id }
    var searchCaption: String {
        switch self {
        case .local(let url): return "Папка / файл · " + url.path
        case .archive(let snapshot, let prefix): return "Архив · " + ArchiveNavigationFrame(snapshot: snapshot).displayPath + " !/" + prefix
        case .remote(let provider, let root): return "Сеть · " + provider.connection.displayName + " · " + root
        }
    }
    var isLocalSearchSource: Bool { if case .local = self { return true }; return false }
    var isArchiveSearchSource: Bool { if case .archive = self { return true }; return false }
}

extension SearchDisplayRow {
    init(_ result: SearchMatch) {
        path = result.displayPath; name = result.name; isDirectory = result.isDirectory
        isSymbolicLink = result.isSymbolicLink; size = result.size; modified = result.modified
        snippet = result.snippet; lineNumber = result.lineNumber
    }
}
