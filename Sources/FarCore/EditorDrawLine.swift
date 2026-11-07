import Foundation

/// One DrawLine editing session. Coordinates are grapheme cells so replacing a
/// single box cell cannot split a UTF-16 surrogate pair.
public struct EditorDrawLine: Sendable {
    public enum Direction: Sendable { case left, up, right, down }
    public private(set) var doubleLine = false
    private var direction: Direction?
    public init() {}

    public mutating func resetDirection() { direction = nil }
    public mutating func toggleStyle() { doubleLine.toggle(); resetDirection() }

    public mutating func draw(in text: String, caret: Int, toward next: Direction, accelerated: Bool,
                              tabSize: Int, fallbackEOL: String) throws -> EditorEdit {
        guard (1...64).contains(tabSize), ["\n", "\r\n", "\r"].contains(fallbackEOL) else {
            throw EditorEditingError.invalidRectangleCoordinate
        }
        let coordinates = FarEditorCoordinates(text), original = text as NSString
        let cursor = coordinates.position(caret)
        var rows = coordinates.lines.map { line in
            Row(body: original.substring(with: line.text), ending: original.substring(with: line.ending))
        }
        let originalRows = rows
        var line = cursor.line - 1
        let prefix = original.substring(with: NSRange(location: coordinates.lines[line].text.location, length: cursor.column - 1))
        var column = try Self.expanded(prefix, tabSize: tabSize).count
        let width = doubleLine ? 2 : 1, count = accelerated ? tabSize : 1
        for _ in 0..<count {
            for index in max(0, line - 1)...min(rows.count - 1, line + 1) where rows[index].body.contains("\t") {
                rows[index].body = try Self.expanded(rows[index].body, tabSize: tabSize)
            }
            if line == rows.count - 1 {
                rows[line].ending = fallbackEOL
                rows.append(Row(body: "", ending: ""))
            }
            if direction == next {
                switch next {
                case .left: column = max(0, column - 1)
                case .right: column += 1
                case .up: line = max(0, line - 1)
                case .down: line += 1
                }
            }
            direction = next
            guard column < EditorEditing.maximumRectangleCoordinate else { throw EditorEditingError.operationTooLarge }
            var body = Array(rows[line].body)
            func neighbor(_ row: Int, _ index: Int) -> Edges {
                guard rows.indices.contains(row), index >= 0,
                      let position = rows[row].body.index(rows[row].body.startIndex, offsetBy: index, limitedBy: rows[row].body.endIndex),
                      position < rows[row].body.endIndex else { return Edges(0) }
                return Edges(Self.codes[rows[row].body[position]] ?? 0)
            }
            var edges = Edges(0)
            edges.left = neighbor(line, column - 1).right
            edges.up = neighbor(line - 1, column).down
            edges.right = neighbor(line, column + 1).left
            edges.down = neighbor(line + 1, column).up
            switch next {
            case .left: edges.left = width; if edges.up == 0, edges.down == 0 { edges.right = width }
            case .right: edges.right = width; if edges.up == 0, edges.down == 0 { edges.left = width }
            case .up: edges.up = width; if edges.left == 0, edges.right == 0 { edges.down = width }
            case .down: edges.down = width; if edges.left == 0, edges.right == 0 { edges.up = width }
            }
            if edges.left != 0, edges.right != 0, edges.left != edges.right { edges.left = width; edges.right = width }
            if edges.up != 0, edges.down != 0, edges.up != edges.down { edges.up = width; edges.down = width }
            if let glyph = Self.glyphs[edges.code] {
                if column >= body.count { body.append(contentsOf: repeatElement(" ", count: column + 1 - body.count)) }
                body[column] = glyph
                rows[line].body = String(body)
            }
        }
        var length = 0, selection = 0, changes: [EditorTextChange] = []
        var result: [String] = []
        for (index, row) in rows.enumerated() {
            if index == line {
                let prefix = row.body.prefix(column)
                selection = length + prefix.utf16.count
            }
            let lineText = row.body + row.ending
            if originalRows.indices.contains(index),
               let change = EditorTextChange.difference(from: originalRows[index].body + originalRows[index].ending,
                   to: lineText, offset: coordinates.lines[index].text.location) {
                changes.append(change)
            }
            length += lineText.utf16.count
            guard length <= EditorEditing.maximumOutputUTF16 else { throw EditorEditingError.operationTooLarge }
            result.append(lineText)
        }
        let appended = rows.dropFirst(originalRows.count).reduce(0) { $0 + $1.body.utf16.count + $1.ending.utf16.count }
        if appended > 0 { changes.append(.init(range: NSRange(location: coordinates.length, length: 0), replacementUTF16Length: appended)) }
        return EditorEdit(text: result.joined(), selection: NSRange(location: selection, length: 0), count: count, changes: changes)
    }

    private struct Row {
        var body: String
        var ending: String
    }

    private static func expanded(_ text: String, tabSize: Int) throws -> String {
        var result = "", column = 0, length = 0
        for character in text {
            if character == "\t" {
                let width = tabSize - column % tabSize
                length += width
                guard length <= EditorEditing.maximumOutputUTF16 else { throw EditorEditingError.operationTooLarge }
                result += String(repeating: " ", count: width)
                column += width
            } else {
                length += character.utf16.count
                guard length <= EditorEditing.maximumOutputUTF16 else { throw EditorEditingError.operationTooLarge }
                result.append(character)
                column += 1
            }
        }
        return result
    }

    private struct Edges {
        var left: Int
        var up: Int
        var right: Int
        var down: Int
        init(_ code: Int) { left = code / 1000; up = code / 100 % 10; right = code / 10 % 10; down = code % 10 }
        var code: Int { left * 1000 + up * 100 + right * 10 + down }
    }

    /// Edge widths in left/up/right/down order.
    private static let codes: [Character: Int] = [
        "─": 1010, "│": 101, "┌": 11, "┐": 1001, "└": 110, "┘": 1100, "├": 111, "┤": 1101, "┬": 1011, "┴": 1110, "┼": 1111,
        "═": 2020, "║": 202, "╒": 21, "╓": 12, "╔": 22, "╕": 2001, "╖": 1002, "╗": 2002, "╘": 120, "╙": 210, "╚": 220,
        "╛": 2100, "╜": 1200, "╝": 2200, "╞": 121, "╟": 212, "╠": 222, "╡": 2101, "╢": 1202, "╣": 2202, "╤": 2021, "╥": 1012,
        "╦": 2022, "╧": 2120, "╨": 1210, "╩": 2220, "╪": 2121, "╫": 1212, "╬": 2222
    ]
    private static let glyphs = Dictionary(uniqueKeysWithValues: codes.map { ($0.value, $0.key) })
}
