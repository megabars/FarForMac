import Foundation

public struct SavedArchiveSearchReference: Codable, Sendable, Equatable {
    public let identity: SavedArchiveIdentity
    public let entry: ArchiveEntry
    public let isReadOnly: Bool
    public let snippet: String?
    public let lineNumber: Int?
    public let byteOffset: Int64?
    public var sourceURL: URL { identity.sourceURL }
    public var canEdit: Bool { !isReadOnly && !entry.isDirectory }
}

public struct SavedRemoteSearchReference: Codable, Sendable, Equatable {
    public let connection: NetworkConnection
    public let entry: RemoteEntry
    public let snippet: String?
    public let lineNumber: Int?
    public let byteOffset: Int64?
}

/// Offline descriptors retain the original search stamps; decoding performs no I/O.
public enum SavedSearchReference: Codable, Sendable, Equatable, Identifiable {
    case local(SearchResult)
    case archive(SavedArchiveSearchReference)
    case remote(SavedRemoteSearchReference)

    private enum Payload: Codable {
        case local(SearchResult)
        case archive(SavedArchiveSearchReference)
        case remote(SavedRemoteSearchReference)
    }
    public init(from decoder: Decoder) throws {
        switch try Payload(from: decoder) {
        case .local(let value): self = .local(value)
        case .archive(let value): self = .archive(value)
        case .remote(let value): self = .remote(value)
        }
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        switch self {
        case .local(let value): try Payload.local(value).encode(to: encoder)
        case .archive(let value): try Payload.archive(value).encode(to: encoder)
        case .remote(let value): try Payload.remote(value).encode(to: encoder)
        }
    }

    public init(capturing match: SearchMatch) throws {
        switch match {
        case .saved(let reference): self = reference
        case .local(let result): self = .local(result)
        case .archive(let result):
            guard let snapshot = result.capturedArchiveSnapshot, let entry = result.archiveEntry else { throw ArchiveError.changedArchive }
            self = .archive(SavedArchiveSearchReference(identity: snapshot.savedIdentity, entry: entry, isReadOnly: snapshot.isReadOnly,
                snippet: result.snippet, lineNumber: result.lineNumber, byteOffset: result.byteOffset))
        case .remote(let result, _):
            guard let connection = result.capturedConnection, let entry = result.remoteEntry else { throw NetworkError.changedSource }
            self = .remote(SavedRemoteSearchReference(connection: connection, entry: entry,
                snippet: result.snippet, lineNumber: result.lineNumber, byteOffset: result.byteOffset))
        }
        try validate()
    }
    public init(match: SearchMatch) throws { try self.init(capturing: match) }
    public var id: String {
        switch self {
        case .local(let value): return "local:" + value.searchIdentityPath
        case .archive(let value): return "archive:" + value.identity.searchIdentity + "|" + String(value.entry.path.utf8.count) + ":" + value.entry.path
        case .remote(let value): return "remote:" + searchConnectionIdentity(value.connection) + "|" + value.entry.path
        }
    }
    public var name: String {
        switch self { case .local(let value): return value.name; case .archive(let value): return value.entry.name; case .remote(let value): return value.entry.name }
    }
    public var displayPath: String {
        switch self { case .local(let value): return value.url.path
        case .archive(let value): return value.identity.displayPath + " !/" + value.entry.path
        case .remote(let value): return SearchLocation.remoteDisplay(value.connection, value.entry.path) }
    }
    public var isDirectory: Bool {
        switch self { case .local(let value): return value.isDirectory; case .archive(let value): return value.entry.isDirectory; case .remote(let value): return value.entry.isDirectory }
    }
    public var isSymbolicLink: Bool {
        switch self { case .local(let value): return value.isSymbolicLink; case .archive: return false; case .remote(let value): return value.entry.isSymbolicLink }
    }
    public var size: Int64 {
        switch self { case .local(let value): return value.size; case .archive(let value): return value.entry.size; case .remote(let value): return value.entry.size }
    }
    public var modified: Date? {
        switch self { case .local(let value): return value.modified; case .archive(let value): return value.entry.modificationDate; case .remote(let value): return value.entry.modified }
    }
    public var snippet: String? {
        switch self { case .local(let value): return value.snippet; case .archive(let value): return value.snippet; case .remote(let value): return value.snippet }
    }
    public var lineNumber: Int? {
        switch self { case .local(let value): return value.lineNumber; case .archive(let value): return value.lineNumber; case .remote(let value): return value.lineNumber }
    }
    public var byteOffset: Int64? {
        switch self { case .local(let value): return value.byteOffset; case .archive(let value): return value.byteOffset; case .remote(let value): return value.byteOffset }
    }
    public var canEdit: Bool {
        guard !isDirectory, !isSymbolicLink else { return false }
        if case .archive(let value) = self { return value.canEdit }
        return true
    }
    public var capturedConnection: NetworkConnection? { if case .remote(let value) = self { return value.connection }; return nil }
    func validate() throws {
        guard size >= 0, (snippet?.utf8.count ?? 0) <= 65_536,
              lineNumber.map({ $0 > 0 }) ?? true, byteOffset.map({ $0 >= 0 && $0 <= size }) ?? true,
              modified.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw PanelSessionError("Неверные метаданные сохранённого результата.") }
        switch self {
        case .local(let value):
            try SavedReferenceValidation.localURL(value.url)
            try value.validateSavedReference()
            guard value.name == value.url.lastPathComponent else { throw PanelSessionError("Имя сохранённого файла не совпадает с путём.") }
        case .archive(let value):
            try value.identity.validate(); try SavedReferenceValidation.archiveEntry(value.entry)
            guard value.isReadOnly || (value.identity.memberChain.isEmpty && !value.entry.isEncrypted) else { throw PanelSessionError("Неверные права сохранённого архива.") }
        case .remote(let value):
            try value.connection.validate(); _ = try RemotePath.validate(value.entry.path)
            guard (value.entry.version?.utf8.count ?? 0) <= 65_536,
                  value.connection.name.utf8.count <= 4096,
                  (value.connection.privateKeyPath?.utf8.count ?? 0) <= 16_384 else { throw PanelSessionError("Слишком длинные метаданные подключения.") }
        }
    }
}

enum SavedReferenceValidation {
    static func localPath(_ path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 16_384, !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw PanelSessionError("Неверный абсолютный путь сохранённого результата.")
        }
    }
    static func localURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              url.path.hasPrefix("/"), url.path.utf8.count <= 16_384, !url.path.contains("\0"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw PanelSessionError("Неверный локальный путь сохранённого результата.")
        }
    }
    static func archiveEntry(_ entry: ArchiveEntry) throws {
        let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
        guard entry.size >= 0, entry.path.utf8.count <= 16_384, !entry.path.contains("\\"), !entry.path.contains(":"),
              !entry.path.contains("\0"), !parts.isEmpty, parts.count <= 128,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
              entry.modificationDate.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw ArchiveError.invalidPath(entry.path) }
    }
}

/// A worker-owned resolver. Cache bounds apply globally to retained nested working copies.
/// Returned snapshots independently retain their workspaces after cleanup or eviction.
public final class SavedSearchResolver {
    public typealias ProviderFactory = (NetworkConnection) throws -> any RemoteProvider
    public typealias ArchivePassword = (URL, [String]) throws -> String?
    public static let maximumCachedArchives = 32
    public static let maximumRetainedBytes: Int64 = 256 * 1024 * 1024
    private let providerFactory: ProviderFactory
    private let archivePassword: ArchivePassword?
    private var archives: [(SavedArchiveIdentity, ArchiveSnapshot)] = []
    private var retainedBytes: Int64 = 0
    public init(providerFactory: @escaping ProviderFactory, archivePassword: ArchivePassword? = nil) {
        self.providerFactory = providerFactory; self.archivePassword = archivePassword
    }
    public func cleanup() { archives.removeAll(); retainedBytes = 0 }
    public func resolve(_ reference: SavedSearchReference,
                        cancellation: ProviderSearchCancellation = ProviderSearchCancellation()) throws -> SearchMatch {
        try reference.validate()
        if cancellation.isCancelled { throw ViewerError.cancelled }
        let match: SearchMatch
        switch reference {
        case .local(let result): try result.verifyCurrent(); match = .local(result)
        case .remote(let value):
            let provider = try providerFactory(value.connection)
            guard provider.connection == value.connection else { throw NetworkError.changedSource }
            let result = ProviderSearchResult(archiveEntry: nil, remoteEntry: value.entry, archiveURL: nil,
                connectionID: value.connection.id, snippet: value.snippet, lineNumber: value.lineNumber,
                byteOffset: value.byteOffset, archiveSnapshot: nil, capturedConnection: value.connection)
            try cancellation.transfer { try result.verifyRemoteCurrent(provider: provider, cancellation: $0) }
            match = .remote(result, provider)
        case .archive(let value):
            let snapshot: ArchiveSnapshot
            if let cached = archives.first(where: { $0.0 == value.identity }) {
                try cached.1.verifyCurrent(); snapshot = cached.1
            } else {
                let bytes = try value.identity.memberChain.reduce(Int64(0)) { sum, entry in
                    guard entry.size <= Self.maximumRetainedBytes - sum else { throw ArchiveError.limitExceeded("рабочие копии сохранённых панелей") }
                    return sum + entry.size
                }
                // Refuse above the global budget rather than evicting live snapshots and
                // accumulating unaccounted working copies in the caller's batch.
                guard archives.count < Self.maximumCachedArchives, bytes <= Self.maximumRetainedBytes - retainedBytes else {
                    throw ArchiveError.limitExceeded("рабочие копии сохранённых панелей; восстановите меньше архивов за один раз")
                }
                snapshot = try cancellation.transfer { try value.identity.restore(cancellation: $0, password: archivePassword) }
                archives.append((value.identity, snapshot)); retainedBytes += bytes
            }
            let result = ProviderSearchResult(archiveEntry: value.entry, remoteEntry: nil, archiveURL: snapshot.sourceURL,
                connectionID: nil, snippet: value.snippet, lineNumber: value.lineNumber, byteOffset: value.byteOffset,
                archiveSnapshot: snapshot, capturedConnection: nil)
            try result.verifyArchiveCurrent(snapshot: snapshot); match = .archive(result)
        }
        if cancellation.isCancelled { throw ViewerError.cancelled }
        return match
    }
}
