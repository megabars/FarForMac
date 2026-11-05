import Foundation

public struct ViewerGotoPosition: Equatable, Sendable {
    public let offset: Int64
    public let column: Int?

    public init(_ expression: String, hexadecimal: Bool, offset: Int64, fileSize: Int64,
                visibleColumn: Int? = nil) throws {
        let (row, col) = try EditorGotoCoordinate.pair(expression, hexadecimal: hexadecimal)
        let size = Int(max(0, fileSize))
        self.offset = Int64(try row.resolve(current: Int(offset), extent: size, maximum: size, oneBased: false))
        if let visibleColumn, col.value != nil {
            column = try col.resolve(current: visibleColumn, extent: 0, maximum: Int.max, oneBased: false)
        } else { column = nil }
    }
}
