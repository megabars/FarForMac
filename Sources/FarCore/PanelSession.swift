import Foundation

public enum PanelContentMode: String, Codable, CaseIterable, Sendable {
    case files, tree, info, quickView
    public var title: String {
        switch self {
        case .files: return "Файлы"
        case .tree: return "Дерево каталогов"
        case .info: return "Информация"
        case .quickView: return "Быстрый просмотр"
        }
    }
}

/// Session records retain original identities, never silently recapture replaced paths.
public struct PanelSession: Codable, Sendable {
    public var directory: String
    public var mode: PanelContentMode
    public var cursorID: String?
    public var filter: String
    public var temporaryItems: [SearchResult]?
    public var directoryCursorID: String?
    public var directoryFilter: String
    public init(directory: String, mode: PanelContentMode = .files, cursorID: String? = nil,
                filter: String = "", temporaryItems: [SearchResult]? = nil,
                directoryCursorID: String? = nil, directoryFilter: String = "") {
        self.directory = directory; self.mode = mode; self.cursorID = cursorID
        self.filter = filter; self.temporaryItems = temporaryItems
        self.directoryCursorID = directoryCursorID; self.directoryFilter = directoryFilter
    }
    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 8 * 1024 * 1024 else { throw PanelSessionError("Сессия панели превышает 8 МиБ.") }
        return data
    }
    public static func decode(_ data: Data) throws -> PanelSession {
        guard data.count <= 8 * 1024 * 1024 else { throw PanelSessionError("Сессия панели превышает 8 МиБ.") }
        let session = try JSONDecoder().decode(Self.self, from: data)
        try session.validate()
        return session
    }
    private func validate() throws {
        guard directory.hasPrefix("/"), !directory.contains("\0"), filter.utf8.count <= 16_384,
              directoryFilter.utf8.count <= 16_384, (temporaryItems?.count ?? 0) <= 10_000,
              temporaryItems?.allSatisfy({ $0.url.isFileURL && $0.url.path.hasPrefix("/") && !$0.url.path.contains("\0") }) ?? true else {
            throw PanelSessionError("Некорректная или слишком большая сессия панели.")
        }
    }
}

public enum TemporaryPanelItems {
    /// First snapshot wins: adding the same path must not bless a replacement object.
    public static func merging(_ existing: [SearchResult], _ additions: [SearchResult]) throws -> [SearchResult] {
        var ids = Set<String>()
        let result = (existing + additions).filter { ids.insert($0.id).inserted }
        guard result.count <= 10_000 else { throw PanelSessionError("Временная панель вмещает до 10 000 объектов.") }
        return result
    }
}

public struct PanelSessionError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
