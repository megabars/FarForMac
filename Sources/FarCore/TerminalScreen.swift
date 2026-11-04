import Foundation

/// A bounded UTF-8 screen with a practical subset of VT/xterm sequences.
/// Unsupported control strings are consumed without executing their payloads.
public struct TerminalScreen: Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var cursorRow = 0
    public private(set) var cursorColumn = 0
    public let scrollbackLimit: Int
    public private(set) var applicationCursorKeys = false
    public private(set) var bracketedPasteEnabled = false
    public private(set) var cursorVisible = true
    /// Untrusted metadata only. Parsing never changes the filesystem or UI.
    public private(set) var title: String?
    public private(set) var reportedWorkingDirectory: URL?
    public private(set) var workingDirectoryReportSequence: UInt64 = 0
    private struct Cell: Sendable {
        var text = " "
        var attributes = TerminalAttributes()
        var continuation = false
        var wide = false
    }
    private var attributes = TerminalAttributes()
    private var grid: [[Cell]]
    private var scrollback: [[Cell]] = []
    private var parser = Parser.text
    private var sequence: [UInt8] = []
    private var sequenceOverflow = false
    private var osc: [UInt8] = []
    private var oscOverflow = false
    private var lastPrinted: (row: Int, column: Int)?
    private var responses = Data()
    private var utf8: [UInt8] = []
    private var expectedUTF8 = 0
    private var savedCursor = SavedCursor()
    private var wrapPending = false
    private var scrollTop = 0
    private var scrollBottom: Int
    private var alternate: Snapshot?
    private enum Parser: Sendable { case text, escape, csi, osc, oscEscape, charset, controlString, controlStringEscape }
    private struct SavedCursor: Sendable {
        var row = 0
        var column = 0
        var attributes = TerminalAttributes()
    }
    private struct Snapshot: Sendable {
        var grid: [[Cell]]
        var row: Int
        var column: Int
        var scrollback: [[Cell]]
        var attributes: TerminalAttributes
        var savedCursor: SavedCursor
        var wrapPending: Bool
        var scrollTop: Int
        var scrollBottom: Int
    }

    public init(columns: Int = 100, rows: Int = 30, scrollbackLimit: Int = 2_000) {
        self.columns = min(500, max(1, columns))
        self.rows = min(200, max(1, rows))
        self.scrollbackLimit = min(20_000, max(0, scrollbackLimit))
        grid = Array(repeating: Array(repeating: Cell(), count: self.columns), count: self.rows)
        scrollBottom = self.rows - 1
    }

    private var displayLines: [[Cell]] {
        scrollback + grid.enumerated().map { row, cells in
            var end = cells.count
            while end > 0 && cells[end - 1].text == " " && cells[end - 1].attributes == TerminalAttributes() { end -= 1 }
            if row == cursorRow { end = max(end, cursorColumn) }
            return Array(cells.prefix(end))
        }
    }
    public var lines: [String] { displayLines.map { $0.map(\.text).joined() } }
    public var plainText: String { lines.joined(separator: "\n") }
    public var styledRuns: [TerminalStyledRun] {
        var runs: [TerminalStyledRun] = []
        var offset = 0
        var pending = ""
        var pendingStyle = TerminalAttributes()
        func flush() {
            guard !pending.isEmpty else { return }
            let end = offset + pending.utf16.count
            runs.append(TerminalStyledRun(text: pending, attributes: pendingStyle, utf16Range: offset..<end))
            offset = end
            pending = ""
        }
        func add(_ text: String, _ attributes: TerminalAttributes) {
            guard !text.isEmpty else { return }
            if pendingStyle != attributes { flush(); pendingStyle = attributes }
            pending.append(contentsOf: text)
        }
        let displayed = displayLines
        for (index, cells) in displayed.enumerated() {
            for cell in cells { add(cell.text, cell.attributes) }
            if index + 1 < displayed.count { add("\n", TerminalAttributes()) }
        }
        flush()
        return runs
    }
    /// UTF-16 position of the terminal caret in `plainText` (for NSTextView).
    public var cursorOffset: Int {
        let before = lines.prefix(scrollback.count + cursorRow)
        return before.reduce(0) { $0 + $1.utf16.count + 1 }
            + grid[cursorRow].prefix(cursorColumn).map(\.text).joined().utf16.count
    }

    public mutating func append(_ data: Data) {
        for byte in data { consume(byte) }
    }
    public mutating func append(_ text: String) { append(Data(text.utf8)) }

    /// Device-status replies only; the caller decides whether to send them to
    /// the PTY. Bounded independently from the rendered screen.
    public mutating func takeResponses() -> Data {
        let result = responses
        responses.removeAll(keepingCapacity: true)
        return result
    }

    public mutating func resize(columns: Int, rows: Int) {
        let width = min(500, max(1, columns))
        let height = min(200, max(1, rows))
        let oldWidth = self.columns
        let wasWrapPending = wrapPending
        func resized(_ cells: [[Cell]], cursor: Int) -> (cells: [[Cell]], removed: [[Cell]], shift: Int) {
            // Preserve the cursor/prompt when the bottom edge moves upward.
            // Discarding the old bottom rows would leave the shell's real
            // prompt outside the displayed buffer until its next redraw.
            let shift = max(0, cursor - height + 1)
            var result = cells.dropFirst(shift).prefix(height).map { Array($0.prefix(width)) + Array(repeating: Cell(), count: max(0, width - $0.count)) }
            result += Array(repeating: Array(repeating: Cell(), count: width), count: max(0, height - result.count))
            for row in result.indices { normalize(&result[row]) }
            return (result, Array(cells.prefix(shift)), shift)
        }
        lastPrinted = nil
        let current = resized(grid, cursor: cursorRow)
        if alternate == nil { retainScrollback(current.removed, in: &scrollback) }
        grid = current.cells
        cursorRow -= current.shift
        savedCursor.row = max(0, savedCursor.row - current.shift)
        if var previous = alternate {
            let main = resized(previous.grid, cursor: previous.row)
            previous.grid = main.cells
            retainScrollback(main.removed, in: &previous.scrollback)
            previous.row = min(height - 1, previous.row - main.shift)
            previous.column = min(width - 1, previous.column + (previous.wrapPending && width > oldWidth ? 1 : 0))
            previous.savedCursor.row = max(0, previous.savedCursor.row - main.shift)
            previous.scrollTop = 0
            previous.scrollBottom = height - 1
            previous.wrapPending = previous.wrapPending && width == oldWidth
            alternate = previous
        }
        self.columns = width
        self.rows = height
        cursorRow = min(height - 1, cursorRow)
        cursorColumn = min(width - 1, cursorColumn + (wasWrapPending && width > oldWidth ? 1 : 0))
        scrollTop = 0
        scrollBottom = height - 1
        wrapPending = wasWrapPending && width == oldWidth
    }

    private mutating func consume(_ byte: UInt8) {
        switch parser {
        case .osc:
            if byte == 7 { finishOSC(); parser = .text }
            else if byte == 27 { parser = .oscEscape }
            else if byte == 24 || byte == 26 { osc.removeAll(keepingCapacity: true); parser = .text }
            else if osc.count < 4096 { osc.append(byte) }
            else { oscOverflow = true }
            return
        case .oscEscape:
            if byte == 92 { finishOSC(); parser = .text }
            else { oscOverflow = true; parser = .osc }
            return
        case .controlString:
            if byte == 27 { parser = .controlStringEscape }
            else if byte == 24 || byte == 26 { parser = .text }
            return
        case .controlStringEscape:
            parser = byte == 92 ? .text : .controlString
            return
        case .charset:
            parser = .text
            return
        case .escape:
            parser = .text
            switch byte {
            case 91: parser = .csi; sequence.removeAll(keepingCapacity: true); sequenceOverflow = false
            case 93: parser = .osc; osc.removeAll(keepingCapacity: true); oscOverflow = false
            case 80, 94, 95: parser = .controlString
            case 40, 41: parser = .charset
            case 55: saveCursor()
            case 56: restoreCursor()
            case 68: lineFeed()
            case 69: cursorColumn = 0; lineFeed()
            case 77: reverseIndex()
            case 99: reset()
            default: break
            }
            return
        case .csi:
            if byte == 27 { parser = .escape }
            else if byte == 24 || byte == 26 { parser = .text }
            else if (0x40...0x7e).contains(byte) {
                if !sequenceOverflow { applyCSI(byte) }
                sequence.removeAll(keepingCapacity: true); parser = .text
            } else if sequence.count < 512 { sequence.append(byte) }
            else { sequenceOverflow = true }
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
        case 27: parser = .escape; lastPrinted = nil
        case 13: lastPrinted = nil; cursorColumn = 0; wrapPending = false
        case 10, 11, 12: lineFeed()
        case 8: lastPrinted = nil; cursorColumn = max(0, cursorColumn - 1); wrapPending = false
        case 9: lastPrinted = nil; cursorColumn = min(columns - 1, (cursorColumn / 8 + 1) * 8); wrapPending = false
        case 0...31, 127: break
        case 0x20...0x7e: put(Unicode.Scalar(byte))
        case 0xc2...0xdf: utf8 = [byte]; expectedUTF8 = 2
        case 0xe0...0xef: utf8 = [byte]; expectedUTF8 = 3
        case 0xf0...0xf4: utf8 = [byte]; expectedUTF8 = 4
        default: put("\u{fffd}")
        }
    }

    private mutating func put(_ scalar: Unicode.Scalar) {
        let text = String(scalar)
        if let previous = lastPrinted, previous.row == cursorRow {
            let old = grid[previous.row][previous.column]
            let combined = old.text + text
            if combined.count == 1 {
                // Bound malicious unending combining/ZWJ clusters without splitting
                // the rejected suffix into thousands of separate screen cells.
                guard combined.utf8.count <= 64 else { return }
                let oldWidth = previous.column + 1 < columns && grid[previous.row][previous.column + 1].continuation ? 2 : 1
                let width = min(columns, TerminalGraphemeWidth.width(combined))
                if previous.column + width > columns {
                    clearCell(row: previous.row, column: previous.column)
                    cursorColumn = 0; lineFeed()
                    write(combined, width: width, style: old.attributes)
                } else {
                    if oldWidth == 2 { grid[previous.row][previous.column + 1] = Cell() }
                    if width == 2 { clearCell(row: previous.row, column: previous.column + 1) }
                    grid[previous.row][previous.column] = Cell(text: combined, attributes: old.attributes, wide: width == 2)
                    if width == 2 { grid[previous.row][previous.column + 1] = Cell(text: "", attributes: old.attributes, continuation: true) }
                    cursorColumn = min(columns - 1, previous.column + width)
                    wrapPending = previous.column + width >= columns
                }
                return
            }
        }
        // A mark without a preceding printed cluster must not change a blank
        // cell or attach to output from before a cursor movement.
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return
        default: break
        }
        if scalar.value == 0x200d { return }
        let width = min(columns, TerminalGraphemeWidth.width(text))
        if wrapPending || cursorColumn + width > columns { cursorColumn = 0; lineFeed() }
        write(text, width: width, style: attributes)
    }

    private mutating func write(_ text: String, width: Int, style: TerminalAttributes) {
        let column = cursorColumn
        clearCell(row: cursorRow, column: column)
        if width == 2 { clearCell(row: cursorRow, column: column + 1) }
        grid[cursorRow][column] = Cell(text: text, attributes: style, wide: width == 2)
        if width == 2 { grid[cursorRow][column + 1] = Cell(text: "", attributes: style, continuation: true) }
        lastPrinted = (cursorRow, column)
        if column + width >= columns { cursorColumn = columns - 1; wrapPending = true }
        else { cursorColumn += width }
    }

    private mutating func clearCell(row: Int, column: Int) {
        if grid[row][column].continuation && column > 0 { grid[row][column - 1] = blankCell() }
        if column + 1 < columns && grid[row][column + 1].continuation { grid[row][column + 1] = blankCell() }
        grid[row][column] = blankCell()
    }
    private func blankCell() -> Cell { Cell(attributes: attributes) }
    private func normalize(_ line: inout [Cell]) {
        for column in line.indices {
            if line[column].continuation {
                if column == 0 || !line[column - 1].wide { line[column] = Cell() }
            } else if line[column].wide && (column + 1 == line.count || !line[column + 1].continuation) {
                line[column] = Cell()
            }
        }
    }

    private mutating func lineFeed() {
        lastPrinted = nil
        wrapPending = false
        if cursorRow == scrollBottom {
            let removed = grid.remove(at: scrollTop)
            if scrollTop == 0 && alternate == nil {
                retainScrollback([removed], in: &scrollback)
            }
            grid.insert(blankLine(), at: scrollBottom)
        } else { cursorRow = min(rows - 1, cursorRow + 1) }
    }
    private func retainScrollback(_ lines: [[Cell]], in buffer: inout [[Cell]]) {
        for var line in lines {
            while line.last?.text == " " && line.last?.attributes == TerminalAttributes() { line.removeLast() }
            buffer.append(line)
        }
        if buffer.count > scrollbackLimit { buffer.removeFirst(buffer.count - scrollbackLimit) }
    }
    private mutating func reverseIndex() {
        lastPrinted = nil
        wrapPending = false
        if cursorRow == scrollTop { grid.remove(at: scrollBottom); grid.insert(blankLine(), at: scrollTop) }
        else { cursorRow = max(0, cursorRow - 1) }
    }
    private mutating func move(row: Int, column: Int) {
        lastPrinted = nil
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
            guard final == 104 || final == 108 else { return }
            guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ";") }) else { return }
            let enabled = final == 104
            for mode in values {
                switch mode {
                case 1: applicationCursorKeys = enabled
                case 25: cursorVisible = enabled
                case 2004: bracketedPasteEnabled = enabled
                default: break
                }
            }
            if values.contains(1049) || values.contains(47) || values.contains(1047) {
                if final == 104 && alternate == nil {
                    alternate = Snapshot(grid: grid, row: cursorRow, column: cursorColumn, scrollback: scrollback,
                                         attributes: attributes, savedCursor: savedCursor, wrapPending: wrapPending,
                                         scrollTop: scrollTop, scrollBottom: scrollBottom)
                    grid = Array(repeating: blankLine(), count: rows); scrollback = []
                    scrollTop = 0; scrollBottom = rows - 1; move(row: 0, column: 0)
                } else if final == 108, let previous = alternate {
                    grid = previous.grid; scrollback = previous.scrollback
                    move(row: previous.row, column: previous.column)
                    attributes = previous.attributes; savedCursor = previous.savedCursor
                    scrollTop = previous.scrollTop; scrollBottom = previous.scrollBottom
                    wrapPending = previous.wrapPending; alternate = nil
                }
            }
            return
        }
        // SGR is the only CSI using colon-delimited subparameters. Other
        // unsupported/intermediate sequences must not become cursor commands.
        if final == 109 { applySGR(source); return }
        guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ";") }) else { return }
        switch final {
        case 110:
            if values == [5] { respond("\u{1b}[0n") }
            else if values == [6] { respond("\u{1b}[\(cursorRow + 1);\(cursorColumn + 1)R") }
        case 99:
            if values == [0] { respond("\u{1b}[?1;2c") }
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
                for column in 0...cursorColumn { clearCell(row: cursorRow, column: column) }
            case 2: grid = Array(repeating: blankLine(), count: rows)
            case 3: scrollback.removeAll()
            default:
                for column in cursorColumn..<columns { clearCell(row: cursorRow, column: column) }
                if cursorRow + 1 < rows { for row in (cursorRow + 1)..<rows { grid[row] = blankLine() } }
            }
        case 75:
            let mode = values.first ?? 0
            let range = mode == 1 ? 0...cursorColumn : mode == 2 ? 0...(columns - 1) : cursorColumn...(columns - 1)
            for column in range { clearCell(row: cursorRow, column: column) }
        case 64:
            let count = min(value(), columns - cursorColumn)
            grid[cursorRow].insert(contentsOf: Array(repeating: blankCell(), count: count), at: cursorColumn)
            grid[cursorRow].removeLast(count)
            normalize(&grid[cursorRow])
        case 80:
            let count = min(value(), columns - cursorColumn)
            grid[cursorRow].removeSubrange(cursorColumn..<(cursorColumn + count))
            grid[cursorRow] += Array(repeating: blankCell(), count: count)
            normalize(&grid[cursorRow])
        case 88:
            for column in cursorColumn..<min(columns, cursorColumn + value()) { clearCell(row: cursorRow, column: column) }
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
        case 115: saveCursor()
        case 117: restoreCursor()
        default: break // Unsupported device queries never leak into text.
        }
    }
    private mutating func saveCursor() {
        savedCursor = SavedCursor(row: cursorRow, column: cursorColumn, attributes: attributes)
    }
    private mutating func restoreCursor() {
        move(row: savedCursor.row, column: savedCursor.column)
        attributes = savedCursor.attributes
    }
    private mutating func reset() {
        attributes = TerminalAttributes()
        applicationCursorKeys = false; bracketedPasteEnabled = false; cursorVisible = true
        title = nil; reportedWorkingDirectory = nil; lastPrinted = nil
        savedCursor = SavedCursor(); responses.removeAll(keepingCapacity: true)
        grid = Array(repeating: blankLine(), count: rows); scrollback.removeAll()
        alternate = nil; scrollTop = 0; scrollBottom = rows - 1; move(row: 0, column: 0)
    }

    private mutating func respond(_ text: String) {
        let bytes = Data(text.utf8)
        if responses.count + bytes.count <= 4096 { responses.append(bytes) }
    }

    private mutating func finishOSC() {
        defer { osc.removeAll(keepingCapacity: true); oscOverflow = false }
        guard !oscOverflow, let source = String(bytes: osc, encoding: .utf8),
              let separator = source.firstIndex(of: ";") else { return }
        let command = source[..<separator]
        let payload = String(source[source.index(after: separator)...])
        guard !payload.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { return }
        switch command {
        case "0", "2":
            if payload.utf8.count <= 1024 { title = payload }
        case "7":
            guard let components = URLComponents(string: payload),
                  components.scheme?.lowercased() == "file", components.path.hasPrefix("/"),
                  components.user == nil, components.password == nil, components.port == nil,
                  components.query == nil, components.fragment == nil,
                  let decodedPath = components.percentEncodedPath.removingPercentEncoding,
                  !decodedPath.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
                  !components.path.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
                  let url = components.url else { return }
            reportedWorkingDirectory = url
            workingDirectoryReportSequence &+= 1
        default: break // Includes clipboard, hyperlinks, notifications and shell integration frames.
        }
    }

    private mutating func applySGR(_ source: String) {
        guard source.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ";" || $0 == ":") }) else { return }
        let fields = source.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < fields.count {
            let parts = fields[index].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let code = parts[0].isEmpty ? 0 : Int(parts[0]) ?? -1
            if code == 4 && parts.count == 2 {
                if parts[1] == "0" { attributes.underline = false }
                else if ["1", "2", "3", "4", "5"].contains(parts[1]) { attributes.underline = true }
            } else if code == 38 || code == 48 {
                var color: TerminalColor?
                if parts.count > 1 {
                    if parts.count == 3, parts[1] == "5", let value = UInt8(parts[2]) { color = .indexed(value) }
                    else if parts.count == 5 || parts.count == 6, parts[1] == "2" {
                        // ISO form permits an empty/zero color-space field;
                        // accept the commonly emitted omitted-field variant.
                        let offset = parts.count == 6 ? 3 : 2
                        if parts.count != 6 || parts[2].isEmpty || parts[2] == "0",
                           let r = UInt8(parts[offset]), let g = UInt8(parts[offset + 1]), let b = UInt8(parts[offset + 2]) { color = .rgb(r, g, b) }
                    }
                } else if index + 1 < fields.count {
                    let kind = fields[index + 1]
                    let count = kind == "5" ? 2 : kind == "2" ? 4 : 1
                    if index + count < fields.count {
                        if kind == "5", let value = UInt8(fields[index + 2]) { color = .indexed(value) }
                        else if kind == "2", let r = UInt8(fields[index + 2]), let g = UInt8(fields[index + 3]), let b = UInt8(fields[index + 4]) { color = .rgb(r, g, b) }
                    }
                    // Consume malformed color operands as well, so a rejected
                    // channel (e.g. 1 or 0) cannot accidentally become bold/reset.
                    index = min(fields.count - 1, index + count)
                }
                if let color {
                    if code == 38 { attributes.foreground = color }
                    else { attributes.background = color }
                }
            } else {
                switch code {
                case 0: attributes = TerminalAttributes()
                case 1: attributes.bold = true
                case 2: attributes.faint = true
                case 3: attributes.italic = true
                case 4, 21: attributes.underline = true
                case 7: attributes.inverse = true
                case 8: attributes.hidden = true
                case 9: attributes.strikethrough = true
                case 22: attributes.bold = false; attributes.faint = false
                case 23: attributes.italic = false
                case 24: attributes.underline = false
                case 27: attributes.inverse = false
                case 28: attributes.hidden = false
                case 29: attributes.strikethrough = false
                case 30...37: attributes.foreground = .indexed(UInt8(code - 30))
                case 40...47: attributes.background = .indexed(UInt8(code - 40))
                case 90...97: attributes.foreground = .indexed(UInt8(code - 90 + 8))
                case 100...107: attributes.background = .indexed(UInt8(code - 100 + 8))
                case 39: attributes.foreground = nil
                case 49: attributes.background = nil
                default: break
                }
            }
            index += 1
        }
    }
    private func blankLine() -> [Cell] { Array(repeating: blankCell(), count: columns) }
}
