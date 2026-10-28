/// Browser-style directory history. Commit a change only after the listing succeeds.
public struct PanelNavigation: Codable, Sendable {
    public private(set) var history: [String]
    public private(set) var position: Int

    public init(path: String) {
        history = [path.isEmpty ? "/" : path]
        position = 0
    }

    public var backPath: String? { position > 0 ? history[position - 1] : nil }
    public var forwardPath: String? { position + 1 < history.count ? history[position + 1] : nil }

    public mutating func visit(_ path: String) {
        guard !path.isEmpty, history[position] != path else { return }
        history = Array(history.prefix(position + 1))
        history.append(path)
        if history.count > 100 { history.removeFirst(history.count - 100) }
        position = history.count - 1
    }

    public mutating func commitBack() {
        if backPath != nil { position -= 1 }
    }

    public mutating func commitForward() {
        if forwardPath != nil { position += 1 }
    }

    private enum CodingKeys: String, CodingKey { case history, position }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = (try? container.decode([String].self, forKey: .history)) ?? []
        let storedPosition = (try? container.decode(Int.self, forKey: .position)) ?? 0
        let clampedPosition = max(0, min(storedPosition, stored.count - 1))
        history = []
        position = 0
        for (index, path) in stored.enumerated() where !path.isEmpty {
            if history.last != path { history.append(path) }
            if index <= clampedPosition { position = history.count - 1 }
        }
        if history.isEmpty { history = ["/"] }
        let excess = max(0, history.count - 100)
        history.removeFirst(excess)
        position = max(0, min(position - excess, history.count - 1))
    }
}
