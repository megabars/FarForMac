import Foundation

/// LuaFar editor positions are 1-based UTF-16 units, not Swift Character offsets.
public struct FarEditorCoordinates: Sendable {
    public struct Line: Sendable {
        public let text: NSRange
        public let ending: NSRange
        public var full: NSRange { NSRange(location: text.location, length: text.length + ending.length) }
    }
    public let lines: [Line]
    public let length: Int
    public init(_ text: String) {
        let units = Array(text.utf16)
        length = units.count
        var result: [Line] = [], start = 0, cursor = 0
        while cursor < units.count {
            if units[cursor] == 10 || units[cursor] == 13 {
                let width = units[cursor] == 13 && cursor + 1 < units.count && units[cursor + 1] == 10 ? 2 : 1
                result.append(Line(text: NSRange(location: start, length: cursor - start), ending: NSRange(location: cursor, length: width)))
                cursor += width; start = cursor
            } else { cursor += 1 }
        }
        result.append(Line(text: NSRange(location: start, length: units.count - start), ending: NSRange(location: units.count, length: 0)))
        lines = result
    }
    public func position(_ offset: Int) -> (line: Int, column: Int) {
        let offset = min(max(0, offset), length)
        let index = lines.lastIndex { $0.text.location <= offset } ?? 0
        return (index + 1, min(offset - lines[index].text.location, lines[index].text.length) + 1)
    }
    public func offset(line: Int, column: Int) -> Int? {
        guard line > 0, line <= lines.count, column > 0, column <= lines[line - 1].text.length + 1 else { return nil }
        return lines[line - 1].text.location + column - 1
    }
}
