import Foundation

/// A bounded UTF-8/VT100 screen used by the native terminal view. It interprets
/// cursor movement and erase sequences rather than displaying escape bytes.
public struct TerminalScreen: Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var cursorRow = 0
    public private(set) var cursorColumn = 0
    public let scrollbackLimit: Int
    private var grid: [[String]]
    private var scrollback: [String] = []
    private var parser = Parser.text
    private var sequence: [UInt8] = []
    private var utf8: [UInt8] = []
    private var expectedUTF8 = 0
    private var savedCursor = (0, 0)
    private var wrapPending = false
    private var scrollTop = 0
    private var scrollBottom: Int
    private var alternate: Snapshot?
    private enum Parser: Sendable { case text, escape, csi, osc, oscEscape, charset }
    private struct Snapshot: Sendable {
        var grid: [[String]]
        var row: Int
        var column: Int
        var scrollback: [String]
    }

    public init(columns: Int = 100, rows: Int = 30, scrollbackLimit: Int = 2_000) {
        self.columns = min(500, max(1, columns))
        self.rows = min(200, max(1, rows))
        self.scrollbackLimit = min(20_000, max(0, scrollbackLimit))
        grid = Array(repeating: Array(repeating: " ", count: self.columns), count: self.rows)
        scrollBottom = self.rows - 1
    }

    public var lines: [String] {
        scrollback + grid.enumerated().map { row, cells in
            var line = cells.joined()
            while line.last == " " { line.removeLast() }
            if row == cursorRow {
                let prefix = cells.prefix(cursorColumn).joined()
                if line.utf16.count < prefix.utf16.count { line = prefix }
            }
            return line
        }
    }
    public var plainText: String { lines.joined(separator: "\n") }
    /// UTF-16 position of the terminal caret in `plainText` (for NSTextView).
    public var cursorOffset: Int {
        let before = lines.prefix(scrollback.count + cursorRow)
        return before.reduce(0) { $0 + $1.utf16.count + 1 }
            + grid[cursorRow].prefix(cursorColumn).joined().utf16.count
    }

    public mutating func append(_ data: Data) {
        for byte in data { consume(byte) }
    }
    public mutating func append(_ text: String) { append(Data(text.utf8)) }

    public mutating func resize(columns: Int, rows: Int) {
        let width = min(500, max(1, columns))
        let height = min(200, max(1, rows))
        func resized(_ cells: [[String]]) -> [[String]] {
            var result = cells.prefix(height).map { Array($0.prefix(width)) + Array(repeating: " ", count: max(0, width - $0.count)) }
            result += Array(repeating: Array(repeating: " ", count: width), count: max(0, height - result.count))
            return result
        }
        grid = resized(grid)
        if var previous = alternate {
            previous.grid = resized(previous.grid)
            previous.row = min(height - 1, previous.row)
            previous.column = min(width - 1, previous.column)
            alternate = previous
        }
        self.columns = width
        self.rows = height
        cursorRow = min(height - 1, cursorRow)
        cursorColumn = min(width - 1, cursorColumn)
        scrollTop = 0
        scrollBottom = height - 1
        wrapPending = false
    }

    private mutating func consume(_ byte: UInt8) {
        switch parser {
        case .osc:
            if byte == 7 { parser = .text }
            else if byte == 27 { parser = .oscEscape }
            return
        case .oscEscape:
            parser = byte == 92 ? .text : .osc
            return
        case .charset:
            parser = .text
            return
        case .escape:
            parser = .text
            switch byte {
            case 91: parser = .csi; sequence.removeAll(keepingCapacity: true)
            case 93: parser = .osc
            case 40, 41: parser = .charset
            case 55: savedCursor = (cursorRow, cursorColumn)
            case 56: move(row: savedCursor.0, column: savedCursor.1)
            case 68: lineFeed()
            case 69: cursorColumn = 0; lineFeed()
            case 77: reverseIndex()
            case 99: reset()
            default: break
            }
            return
        case .csi:
            if (0x40...0x7e).contains(byte) { applyCSI(byte); sequence.removeAll(keepingCapacity: true); parser = .text }
            else if sequence.count < 128 { sequence.append(byte) }
            else { sequence.removeAll(keepingCapacity: true); parser = .text }
            return
        case .text: break
        }
        if !utf8.isEmpty {
            if byte & 0xc0 == 0x80 {
                utf8.append(byte)
                if utf8.count == expectedUTF8 {
                    for scalar in String(decoding: utf8, as: UTF8.self).unicodeScalars { put(scalar) }
                    utf8.removeAll(keepingCapacity: true)
                }
                return
            }
            put("\u{fffd}")
            utf8.removeAll(keepingCapacity: true)
        }
        switch byte {
        case 27: parser = .escape
        case 13: cursorColumn = 0; wrapPending = false
        case 10, 11, 12: lineFeed()
        case 8: cursorColumn = max(0, cursorColumn - 1); wrapPending = false
        case 9: cursorColumn = min(columns - 1, (cursorColumn / 8 + 1) * 8); wrapPending = false
        case 0...31, 127: break
        case 0x20...0x7e: put(Unicode.Scalar(byte))
        case 0xc2...0xdf: utf8 = [byte]; expectedUTF8 = 2
        case 0xe0...0xef: utf8 = [byte]; expectedUTF8 = 3
        case 0xf0...0xf4: utf8 = [byte]; expectedUTF8 = 4
        default: put("\u{fffd}")
        }
    }

    private mutating func put(_ scalar: Unicode.Scalar) {
        if scalar.properties.canonicalCombiningClass != .notReordered || scalar.value == 0xfe0f {
            var column = wrapPending ? cursorColumn : max(0, cursorColumn - 1)
            if grid[cursorRow][column].isEmpty && column > 0 { column -= 1 }
            if grid[cursorRow][column].utf8.count < 32 {
                grid[cursorRow][column] += String(scalar)
            }
            return
        }
        let value = scalar.value
        let wide = (0x1100...0x115f).contains(value) || (0x2e80...0xa4cf).contains(value)
            || (0xac00...0xd7a3).contains(value) || (0xf900...0xfaff).contains(value)
            || (0xfe10...0xfe6f).contains(value) || (0xff00...0xff60).contains(value)
            || (0x1f300...0x1faff).contains(value) || (0x20000...0x3ffff).contains(value)
        let width = wide && columns > 1 ? 2 : 1
        if wrapPending || cursorColumn + width > columns { cursorColumn = 0; lineFeed() }
        if grid[cursorRow][cursorColumn].isEmpty && cursorColumn > 0 {
            grid[cursorRow][cursorColumn - 1] = " "
        }
        if cursorColumn + 1 < columns && grid[cursorRow][cursorColumn + 1].isEmpty {
            grid[cursorRow][cursorColumn + 1] = " "
        }
        if width == 2 && cursorColumn + 2 < columns && grid[cursorRow][cursorColumn + 2].isEmpty {
            grid[cursorRow][cursorColumn + 2] = " "
        }
        grid[cursorRow][cursorColumn] = String(scalar)
        if width == 2 { grid[cursorRow][cursorColumn + 1] = "" }
        if cursorColumn + width >= columns { cursorColumn = columns - 1; wrapPending = true }
        else { cursorColumn += width }
    }

    private mutating func lineFeed() {
        wrapPending = false
        if cursorRow == scrollBottom {
            let removed = grid.remove(at: scrollTop)
            if scrollTop == 0 && alternate == nil {
                scrollback.append(trim(removed.joined()))
                if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
            }
            grid.insert(blankLine(), at: scrollBottom)
        } else { cursorRow = min(rows - 1, cursorRow + 1) }
    }
    private mutating func reverseIndex() {
        wrapPending = false
        if cursorRow == scrollTop { grid.remove(at: scrollBottom); grid.insert(blankLine(), at: scrollTop) }
        else { cursorRow = max(0, cursorRow - 1) }
    }
    private mutating func move(row: Int, column: Int) {
        cursorRow = min(rows - 1, max(0, row))
        cursorColumn = min(columns - 1, max(0, column))
        wrapPending = false
    }
    private mutating func applyCSI(_ final: UInt8) {
        let source = String(decoding: sequence, as: UTF8.self)
        let isPrivate = source.first == "?"
        let text = isPrivate ? String(source.dropFirst()) : source
        let values = text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func value(_ index: Int = 0, default fallback: Int = 1) -> Int {
            guard index < values.count, values[index] > 0 else { return fallback }
            return min(100_000, values[index])
        }
        if isPrivate {
            if values.contains(1049) || values.contains(47) || values.contains(1047) {
                if final == 104 && alternate == nil {
                    alternate = Snapshot(grid: grid, row: cursorRow, column: cursorColumn, scrollback: scrollback)
                    grid = Array(repeating: blankLine(), count: rows); scrollback = []; move(row: 0, column: 0)
                } else if final == 108, let previous = alternate {
                    grid = previous.grid; scrollback = previous.scrollback
                    move(row: previous.row, column: previous.column); alternate = nil
                }
            }
            return
        }
        switch final {
        case 65: move(row: cursorRow - value(), column: cursorColumn)
        case 66: move(row: cursorRow + value(), column: cursorColumn)
        case 67: move(row: cursorRow, column: cursorColumn + value())
        case 68: move(row: cursorRow, column: cursorColumn - value())
        case 69: move(row: cursorRow + value(), column: 0)
        case 70: move(row: cursorRow - value(), column: 0)
        case 71, 96: move(row: cursorRow, column: value() - 1)
        case 100: move(row: value() - 1, column: cursorColumn)
        case 72, 102: move(row: value() - 1, column: value(1) - 1)
        case 74:
            switch values.first ?? 0 {
            case 1:
                for row in 0..<cursorRow { grid[row] = blankLine() }
                for column in 0...cursorColumn { grid[cursorRow][column] = " " }
            case 2: grid = Array(repeating: blankLine(), count: rows)
            case 3: scrollback.removeAll()
            default:
                for column in cursorColumn..<columns { grid[cursorRow][column] = " " }
                if cursorRow + 1 < rows { for row in (cursorRow + 1)..<rows { grid[row] = blankLine() } }
            }
        case 75:
            let mode = values.first ?? 0
            let range = mode == 1 ? 0...cursorColumn : mode == 2 ? 0...(columns - 1) : cursorColumn...(columns - 1)
            for column in range { grid[cursorRow][column] = " " }
        case 64:
            let count = min(value(), columns - cursorColumn)
            grid[cursorRow].insert(contentsOf: Array(repeating: " ", count: count), at: cursorColumn)
            grid[cursorRow].removeLast(count)
        case 80:
            let count = min(value(), columns - cursorColumn)
            grid[cursorRow].removeSubrange(cursorColumn..<(cursorColumn + count))
            grid[cursorRow] += Array(repeating: " ", count: count)
        case 88:
            for column in cursorColumn..<min(columns, cursorColumn + value()) { grid[cursorRow][column] = " " }
        case 76:
            if (scrollTop...scrollBottom).contains(cursorRow) {
                for _ in 0..<min(value(), scrollBottom - cursorRow + 1) { grid.remove(at: scrollBottom); grid.insert(blankLine(), at: cursorRow) }
            }
        case 77:
            if (scrollTop...scrollBottom).contains(cursorRow) {
                for _ in 0..<min(value(), scrollBottom - cursorRow + 1) { grid.remove(at: cursorRow); grid.insert(blankLine(), at: scrollBottom) }
            }
        case 83: for _ in 0..<min(rows, value()) { let saved = cursorRow; cursorRow = scrollBottom; lineFeed(); cursorRow = saved }
        case 84: for _ in 0..<min(rows, value()) { let saved = cursorRow; cursorRow = scrollTop; reverseIndex(); cursorRow = saved }
        case 114:
            let top = value() - 1, bottom = value(1, default: rows) - 1
            if top >= 0 && top < bottom && bottom < rows { scrollTop = top; scrollBottom = bottom; move(row: 0, column: 0) }
        case 115: savedCursor = (cursorRow, cursorColumn)
        case 117: move(row: savedCursor.0, column: savedCursor.1)
        default: break // SGR and unsupported device queries never leak into text.
        }
    }
    private mutating func reset() {
        grid = Array(repeating: blankLine(), count: rows); scrollback.removeAll()
        alternate = nil; scrollTop = 0; scrollBottom = rows - 1; move(row: 0, column: 0)
    }
    private func blankLine() -> [String] { Array(repeating: " ", count: columns) }
    private func trim(_ text: String) -> String {
        var result = text
        while result.last == " " { result.removeLast() }
        return result
    }
}
