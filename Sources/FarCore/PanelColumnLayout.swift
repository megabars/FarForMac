import Foundation

/// Stable identifiers keep saved geometry independent of translated column titles.
public struct PanelColumnLayout: Codable, Equatable, Sendable {
    public let version: Int
    public let order: [String]
    public let widths: [String: Double]
    public init(order: [String], widths: [String: Double]) throws {
        version = 1; self.order = order; self.widths = widths
        try validate()
    }
    public func encoded() throws -> Data { try validate(); return try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32_768 else { throw PanelSessionError("Слишком большой файл расположения колонок.") }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
    /// Obsolete columns disappear, new ones retain their default place at the end.
    public func orderedColumns(available: [String]) -> [String] {
        let valid = Set(available), saved = order.filter { valid.contains($0) }
        return saved + available.filter { !saved.contains($0) }
    }
    private func validate() throws {
        guard version == 1, order.count <= 64, widths.count <= 64,
              Set(order).count == order.count,
              (order + Array(widths.keys)).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              widths.values.allSatisfy({ $0.isFinite && (20...4096).contains($0) }) else {
            throw PanelSessionError("Некорректные настройки расположения колонок.")
        }
    }
}
