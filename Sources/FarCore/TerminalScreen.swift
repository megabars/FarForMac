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
    public private(set) var applicationKeypad = false
    public private(set) var focusReportingEnabled = false
    public private(set) var alternateScrollEnabled = true
    public private(set) var mouseReporting = TerminalMouseReporting()
    public private(set) var reverseVideo = false
    public private(set) var cursorShape: TerminalCursorShape = .defaultBlock
    public private(set) var palette: [UInt8: TerminalColor] = [:]
    public private(set) var defaultForeground: TerminalColor?
    public private(set) var defaultBackground: TerminalColor?
    public private(set) var cursorColor: TerminalColor?
    public var hostForeground = TerminalColor.rgb(224, 235, 250)
    public var hostBackground = TerminalColor.rgb(9, 17, 33)
    public var isAlternateScreen: Bool { alternate != nil }
    public var scrollbackCount: Int { scrollback.count }
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
        var printed = false
    }
    private struct Row: Sendable {
        var cells: [Cell]
        /// Count of source cells before an automatic continuation. A wide
        /// glyph may wrap before the final physical column.
        var wrappedColumns: Int?
        var contentCount: Int {
            guard let last = cells.lastIndex(where: { $0.printed || $0.continuation || $0.attributes != TerminalAttributes() }) else { return 0 }
            return last + 1
        }
        subscript(column: Int) -> Cell {
            get { cells[column] }
            set { cells[column] = newValue }
        }
    }
    private var attributes = TerminalAttributes()
    private var grid: [Row]
    private var scrollback: [Row] = []
    private var alternateGrid: [Row]?
    private var alternateSavedCursor = SavedCursor()
    private var originMode = false
    private var autoWrap = true
    private var insertMode = false
    private var lineFeedNewLine = false
    private var g0Graphics = false
    private var g1Graphics = false
    private var useG1 = false
    private var tabStops: Set<Int>
    private var lastGraphic: String?
    private var iconTitle: String?
    private var titles: [(title: String?, icon: String?)] = []
    private var parser = Parser.text
    private var sequence: [UInt8] = []
    private var sequenceOverflow = false
    private var dcs = false
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
    private enum Parser: Sendable { case text, escape, escapeIntermediate(UInt8), csi, osc, oscEscape, charset(Bool), controlString, controlStringEscape }
    private struct SavedCursor: Sendable {
        var row = 0
        var column = 0
        var attributes = TerminalAttributes()
        var wrapPending = false
        var originMode = false
        var autoWrap = true
        var g0Graphics = false
        var g1Graphics = false
        var useG1 = false
    }
    private struct Snapshot: Sendable {
        var grid: [Row]
        var row: Int
        var column: Int
        var scrollback: [Row]
        var attributes: TerminalAttributes
        var savedCursor: SavedCursor
        var wrapPending: Bool
        var scrollTop: Int
        var scrollBottom: Int
        var originMode: Bool
        var autoWrap: Bool
        var restoreCursorOnExit: Bool
        var g0Graphics: Bool
        var g1Graphics: Bool
        var useG1: Bool
    }

    public init(columns: Int = 100, rows: Int = 30, scrollbackLimit: Int = 2_000) {
        self.columns = min(500, max(1, columns))
        self.rows = min(200, max(1, rows))
        self.scrollbackLimit = min(20_000, max(0, scrollbackLimit))
        grid = Array(repeating: Row(cells: Array(repeating: Cell(), count: self.columns)), count: self.rows)
        tabStops = Set(stride(from: 8, to: self.columns, by: 8))
        scrollBottom = self.rows - 1
    }

    private var displayLines: [[Cell]] {
        scrollback.map(\.cells) + grid.enumerated().map { row, line in
            var end = line.contentCount
            if row == cursorRow { end = max(end, cursorColumn) }
            return Array(line.cells.prefix(end))
        }
    }
    public var displayCells: [[TerminalDisplayCell]] {
        displayLines.map { cells in
            cells.enumerated().compactMap { column, cell in
                guard !cell.continuation else { return nil }
                return TerminalDisplayCell(column: column, width: cell.wide ? 2 : 1, text: cell.text, attributes: cell.attributes)
            }
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
            + grid[cursorRow].cells.prefix(cursorColumn).map(\.text).joined().utf16.count
    }

    public mutating func append(_ data: Data) {
        for byte in data { consume(byte) }
    }
    public mutating func append(_ text: String) { append(Data(text.utf8)) }

    /// A separately dispatched command gets a fresh terminal mode and parser,
    /// while the menu keeps one visible transcript.
    public mutating func continueWithNewProcess() {
        finishProcess()
        attributes = TerminalAttributes()
        originMode = false; autoWrap = true; insertMode = false; lineFeedNewLine = false
        g0Graphics = false; g1Graphics = false; useG1 = false; lastGraphic = nil
        tabStops = Set(stride(from: 8, to: columns, by: 8))
        title = nil; iconTitle = nil; titles.removeAll(); reportedWorkingDirectory = nil
        palette.removeAll(); defaultForeground = nil; defaultBackground = nil; cursorColor = nil
        reverseVideo = false; cursorShape = .defaultBlock
        savedCursor = SavedCursor()
        alternateGrid = nil; alternateSavedCursor = SavedCursor()
        scrollTop = 0; scrollBottom = rows - 1
        wrapPending = false
        if cursorColumn != 0 || grid[cursorRow].contentCount != 0 { append("\r\n") }
    }

    /// A child may exit without restoring the primary screen or its input modes.
    public mutating func finishProcess() {
        if !utf8.isEmpty { put("\u{fffd}") }
        leaveAlternateScreen(restoreCursor: true)
        parser = .text
        sequence.removeAll(); sequenceOverflow = false; dcs = false
        osc.removeAll(); oscOverflow = false
        utf8.removeAll(); expectedUTF8 = 0; lastPrinted = nil
        responses.removeAll()
        resetInputModes()
    }

    private mutating func resetInputModes() {
        applicationCursorKeys = false; applicationKeypad = false; bracketedPasteEnabled = false
        cursorVisible = true; focusReportingEnabled = false; alternateScrollEnabled = true
        mouseReporting = TerminalMouseReporting()
    }

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
        guard width != self.columns || height != self.rows else { return }
        let oldWidth = self.columns
        let oldHeight = self.rows
        if var primary = alternate {
            Self.resizeGrid(&primary.grid, history: &primary.scrollback, cursorRow: &primary.row,
                       cursorColumn: &primary.column, pending: &primary.wrapPending, saved: &primary.savedCursor,
                       lastPrint: nil, width: width, height: height, reflow: true, scrollbackLimit: scrollbackLimit)
            Self.resizeMargins(top: &primary.scrollTop, bottom: &primary.scrollBottom, oldHeight: oldHeight, height: height)
            alternate = primary
        }
        lastPrinted = Self.resizeGrid(&grid, history: &scrollback, cursorRow: &cursorRow, cursorColumn: &cursorColumn,
                                 pending: &wrapPending, saved: &savedCursor, lastPrint: lastPrinted,
                                 width: width, height: height, reflow: alternate == nil, scrollbackLimit: scrollbackLimit)
        if var inactive = alternateGrid {
            var history: [Row] = [], row = alternateSavedCursor.row, column = alternateSavedCursor.column
            var pending = alternateSavedCursor.wrapPending
            _ = Self.resizeGrid(&inactive, history: &history, cursorRow: &row, cursorColumn: &column, pending: &pending,
                           saved: &alternateSavedCursor, lastPrint: nil, width: width, height: height, reflow: false, scrollbackLimit: 0)
            alternateGrid = inactive
        }
        Self.resizeMargins(top: &scrollTop, bottom: &scrollBottom, oldHeight: oldHeight, height: height)
        if width > oldWidth {
            tabStops.formUnion(stride(from: ((oldWidth + 7) / 8) * 8, to: width, by: 8))
        } else { tabStops = tabStops.filter { $0 < width } }
        self.columns = width
        self.rows = height
    }

    private static func resizeMargins(top: inout Int, bottom: inout Int, oldHeight: Int, height: Int) {
        bottom = bottom == oldHeight - 1 ? height - 1 : min(bottom, height - 1)
        if top >= bottom { top = 0; bottom = height - 1 }
    }

    private struct Position {
        var row: Int
        var column: Int
        var pending = false
    }

    @discardableResult
    private static func resizeGrid(_ grid: inout [Row], history: inout [Row], cursorRow: inout Int, cursorColumn: inout Int,
                            pending: inout Bool, saved: inout SavedCursor, lastPrint: (row: Int, column: Int)?,
                            width: Int, height: Int, reflow: Bool, scrollbackLimit: Int) -> (row: Int, column: Int)? {
        let blank = Row(cells: Array(repeating: Cell(), count: width))
        let oldWidth = grid[0].cells.count
        var cursor = Position(row: cursorRow, column: cursorColumn, pending: pending)
        var stored = Position(row: saved.row, column: saved.column, pending: saved.wrapPending)
        var graphic = lastPrint.map { Position(row: $0.row, column: $0.column) }
        var firstVisible = 0
        var firstRetained = 0
        var all: [Row]
        if reflow && width != oldWidth {
            let historyCount = history.count
            let markers = [Position(row: historyCount, column: 0),
                           Position(row: historyCount + cursor.row, column: cursor.column, pending: cursor.pending),
                           Position(row: historyCount + stored.row, column: stored.column, pending: stored.pending),
                           graphic.map { Position(row: historyCount + $0.row, column: $0.column) }]
            let result = reflowRows(history + grid, width: width, markers: markers, historyCount: historyCount, scrollbackLimit: scrollbackLimit)
            all = result.rows
            firstRetained = result.firstRetained
            firstVisible = result.markers[0]?.row ?? 0
            cursor = result.markers[1] ?? cursor
            stored = result.markers[2] ?? stored
            graphic = result.markers[3]
        } else {
            if reflow {
                firstVisible = history.count
                cursor.row += firstVisible; stored.row += firstVisible
                graphic?.row += firstVisible
            }
            all = history + grid.map { row in
                var line = Array(row.cells.prefix(width))
                line += Array(repeating: Cell(), count: width - line.count)
                normalize(&line)
                return Row(cells: line, wrappedColumns: row.wrappedColumns)
            }
            if width != oldWidth {
                cursor.column += cursor.pending && width > oldWidth ? 1 : 0
                stored.column += stored.pending && width > oldWidth ? 1 : 0
                cursor.pending = false; stored.pending = false
                if let previous = graphic, previous.column >= width || all[previous.row].cells[previous.column].text == " " {
                    graphic = nil
                }
            }
        }
        let top = max(firstVisible, cursor.row - height + 1)
        let start = max(0, top - firstRetained)
        let end = min(start + height, all.count)
        grid = all[start..<end].map { row in
            var row = row
            row.cells += Array(repeating: Cell(), count: width - row.cells.count)
            return row
        }
        grid += Array(repeating: blank, count: height - grid.count)
        if reflow {
            history = all[max(0, start - scrollbackLimit)..<start].map(trimHistory)
        }
        cursorRow = cursor.row - top
        cursorColumn = min(width - 1, cursor.column)
        pending = cursor.pending
        saved.row = min(height - 1, max(0, stored.row - top))
        saved.column = min(width - 1, stored.column)
        saved.wrapPending = stored.pending
        guard let graphic, (top..<(top + height)).contains(graphic.row) else { return nil }
        return (graphic.row - top, graphic.column)
    }

    private static func reflowRows(_ source: [Row], width: Int, markers: [Position?], historyCount: Int, scrollbackLimit: Int)
        -> (rows: [Row], firstRetained: Int, markers: [Position?]) {
        var output: [Row] = []
        var firstRetained = 0
        var mapped = markers.map { _ in Optional<Position>.none }
        var cells: [Cell] = []
        func flush(wrapped: Bool, inHistory: Bool) {
            let row = Row(cells: cells, wrappedColumns: wrapped ? cells.count : nil)
            output.append(row)
            cells.removeAll(keepingCapacity: true)
            // Reflowing deep history from 500 columns to one must not store
            // every intermediate row. Keep enough for all history and margins.
            if inHistory && output.count > scrollbackLimit + 1024 {
                let drop = output.count - scrollbackLimit
                output.removeFirst(drop)
                firstRetained += drop
            }
        }
        for (rowIndex, row) in source.enumerated() {
            let inHistory = rowIndex < historyCount
            let local = markers.indices.filter { markers[$0]?.row == rowIndex }
            let markerEnd = local.compactMap { markers[$0] }.map { $0.column + ($0.pending ? 1 : 0) }.max() ?? 0
            let end = max(row.contentCount, row.wrappedColumns ?? 0, markerEnd)
            func map(_ oldColumn: Int, nextColumn: Int, pendingOnly: Bool = false) {
                for index in local {
                    guard let mark = markers[index], mapped[index] == nil,
                          !pendingOnly || mark.pending, oldColumn == mark.column + (mark.pending ? 1 : 0) else { continue }
                    mapped[index] = Position(row: firstRetained + output.count, column: min(width - 1, nextColumn),
                                             pending: nextColumn == width)
                }
            }
            var column = 0
            while column < end {
                let cell = column < row.cells.count ? row[column] : Cell()
                if cell.continuation { column += 1; continue }
                let newWidth = min(width, cell.wide || (cell.printed && TerminalGraphemeWidth.width(cell.text) == 2) ? 2 : 1)
                map(column, nextColumn: cells.count, pendingOnly: true)
                if cells.count + newWidth > width { flush(wrapped: true, inHistory: inHistory) }
                map(column, nextColumn: cells.count)
                if cell.wide && column + 1 < end { map(column + 1, nextColumn: cells.count + newWidth - 1) }
                var lead = cell
                lead.wide = newWidth == 2
                cells.append(lead)
                if lead.wide { cells.append(Cell(text: "", attributes: lead.attributes, continuation: true)) }
                column += cell.wide ? 2 : 1
            }
            map(end, nextColumn: cells.count)
            if row.wrappedColumns == nil { flush(wrapped: false, inHistory: inHistory) }
        }
        if !cells.isEmpty { flush(wrapped: false, inHistory: false) }
        return (output, firstRetained, mapped)
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
            else if dcs && sequence.count < 64 { sequence.append(byte) }
            else { sequenceOverflow = true }
            return
        case .controlStringEscape:
            if byte == 92 {
                if dcs && !sequenceOverflow { finishDCS() }
                parser = .text
            } else {
                sequenceOverflow = true
                parser = byte == 27 ? .controlStringEscape : .controlString
            }
            return
        case let .charset(second):
            if byte == 48 || byte == 66 || byte == 65 {
                if second { g1Graphics = byte == 48 }
                else { g0Graphics = byte == 48 }
            }
            parser = byte == 27 ? .escape : .text
            return
        case let .escapeIntermediate(intermediate):
            if intermediate == 35, byte == 56 {
                let line = Row(cells: Array(repeating: Cell(text: "E", printed: true), count: columns))
                grid = Array(repeating: line, count: rows)
            }
            parser = byte == 27 ? .escape : .text
            return
        case .escape:
            parser = .text
            switch byte {
            case 91: parser = .csi; sequence.removeAll(keepingCapacity: true); sequenceOverflow = false
            case 93: parser = .osc; osc.removeAll(keepingCapacity: true); oscOverflow = false
            case 80, 88, 94, 95:
                parser = .controlString
                dcs = byte == 80; sequence.removeAll(keepingCapacity: true); sequenceOverflow = false
            case 40, 41: parser = .charset(byte == 41)
            case 32...35, 36...39, 42...47: parser = .escapeIntermediate(byte)
            case 61: applicationKeypad = true
            case 62: applicationKeypad = false
            case 72: tabStops.insert(cursorColumn)
            case 90: respond("\u{1b}[?1;2c")
            case 27: parser = .escape
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
            else if byte < 32 { applyControl(byte) }
            else if byte == 127 { break }
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
        case 0...31, 127: applyControl(byte)
        case 0x20...0x7e:
            let graphics = useG1 ? g1Graphics : g0Graphics
            put(graphics ? Self.decGraphics[byte] ?? Unicode.Scalar(byte) : Unicode.Scalar(byte))
        case 0xc2...0xdf: utf8 = [byte]; expectedUTF8 = 2
        case 0xe0...0xef: utf8 = [byte]; expectedUTF8 = 3
        case 0xf0...0xf4: utf8 = [byte]; expectedUTF8 = 4
        default: put("\u{fffd}")
        }
    }

    private static let decGraphics: [UInt8: Unicode.Scalar] = {
        let glyphs = "◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·"
        return Dictionary(uniqueKeysWithValues: zip(UInt8(96)...UInt8(126), glyphs.unicodeScalars))
    }()

    private mutating func applyControl(_ byte: UInt8) {
        switch byte {
        case 8: move(row: cursorRow, column: cursorColumn - 1)
        case 9: tab(by: 1)
        case 10, 11, 12:
            if lineFeedNewLine { cursorColumn = 0 }
            lineFeed()
        case 13: move(row: cursorRow, column: 0)
        case 14: useG1 = true; lastPrinted = nil
        case 15: useG1 = false; lastPrinted = nil
        default: break
        }
    }

    private mutating func tab(by count: Int) {
        let stops = tabStops.sorted()
        let target = count > 0
            ? stops.filter { $0 > cursorColumn }.dropFirst(count - 1).first ?? (columns - 1)
            : stops.reversed().filter { $0 < cursorColumn }.dropFirst(-count - 1).first ?? 0
        move(row: cursorRow, column: target)
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
                    if autoWrap {
                        clearCell(row: previous.row, column: previous.column)
                        wrap(at: previous.column)
                        write(combined, width: width, style: old.attributes)
                    }
                } else {
                    if oldWidth == 2 { grid[previous.row][previous.column + 1] = Cell() }
                    if width == 2 { clearCell(row: previous.row, column: previous.column + 1) }
                    grid[previous.row][previous.column] = Cell(text: combined, attributes: old.attributes, wide: width == 2, printed: true)
                    if width == 2 { grid[previous.row][previous.column + 1] = Cell(text: "", attributes: old.attributes, continuation: true) }
                    cursorColumn = min(columns - 1, previous.column + width)
                    wrapPending = autoWrap && previous.column + width >= columns
                    lastGraphic = combined
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
        if scalar.properties.generalCategory == .format { return }
        let width = min(columns, TerminalGraphemeWidth.width(text))
        if wrapPending { wrap(at: columns) }
        if cursorColumn + width > columns {
            guard autoWrap else { return }
            wrap(at: cursorColumn)
        }
        if insertMode { insertCells(width) }
        write(text, width: width, style: attributes)
    }

    private mutating func write(_ text: String, width: Int, style: TerminalAttributes) {
        let column = cursorColumn
        clearCell(row: cursorRow, column: column)
        if width == 2 { clearCell(row: cursorRow, column: column + 1) }
        grid[cursorRow][column] = Cell(text: text, attributes: style, wide: width == 2, printed: true)
        if width == 2 { grid[cursorRow][column + 1] = Cell(text: "", attributes: style, continuation: true) }
        lastPrinted = (cursorRow, column)
        lastGraphic = text
        if column + width >= columns { cursorColumn = columns - 1; wrapPending = autoWrap }
        else { cursorColumn += width }
    }

    private mutating func clearCell(row: Int, column: Int) {
        if grid[row][column].continuation && column > 0 { grid[row][column - 1] = blankCell() }
        if column + 1 < columns && grid[row][column + 1].continuation { grid[row][column + 1] = blankCell() }
        grid[row][column] = blankCell()
    }
    private func blankCell() -> Cell {
        var erase = TerminalAttributes()
        erase.background = attributes.inverse ? attributes.foreground : attributes.background
        return Cell(attributes: erase)
    }
    private static func normalize(_ line: inout [Cell]) {
        for column in line.indices {
            if line[column].continuation {
                if column == 0 || !line[column - 1].wide { line[column] = Cell() }
            } else if line[column].wide && (column + 1 == line.count || !line[column + 1].continuation) {
                line[column] = Cell()
            }
        }
    }

    private mutating func wrap(at column: Int) {
        if cursorRow < rows - 1 || cursorRow == scrollBottom { grid[cursorRow].wrappedColumns = column }
        cursorColumn = 0
        lineFeed()
    }
    private mutating func lineFeed() {
        lastPrinted = nil
        wrapPending = false
        if cursorRow == scrollBottom {
            let removed = grid.remove(at: scrollTop)
            if scrollTop == 0 && alternate == nil && scrollbackLimit > 0 {
                scrollback.append(Self.trimHistory(removed))
                if scrollback.count > scrollbackLimit { scrollback.removeFirst() }
            }
            grid.insert(blankLine(), at: scrollBottom)
        } else { cursorRow = min(rows - 1, cursorRow + 1) }
    }
    private static func trimHistory(_ row: Row) -> Row {
        let count = max(row.contentCount, row.wrappedColumns ?? 0)
        return Row(cells: Array(row.cells.prefix(count)), wrappedColumns: row.wrappedColumns)
    }
    private mutating func insertCells(_ count: Int) {
        grid[cursorRow].cells.insert(contentsOf: Array(repeating: blankCell(), count: count), at: cursorColumn)
        grid[cursorRow].cells.removeLast(count)
        Self.normalize(&grid[cursorRow].cells)
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
        let prefix = source.first
        let hasPrefix = prefix == "?" || prefix == ">"
        let text = hasPrefix ? String(source.dropFirst()) : source
        let values = text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func value(_ index: Int = 0, default fallback: Int = 1) -> Int {
            guard index < values.count, values[index] > 0 else { return fallback }
            return min(100_000, values[index])
        }
        if source == "!", final == 112 { softReset(); return }
        if source.hasSuffix(" "), final == 113, let shape = Int(source.dropLast().isEmpty ? "0" : source.dropLast()),
           let cursor = TerminalCursorShape(rawValue: shape) {
            cursorShape = cursor
            return
        }
        if source.hasSuffix("$"), final == 112 {
            let privateMode = prefix == "?"
            let field = privateMode ? source.dropFirst().dropLast() : source.dropLast()
            if let mode = Int(field), mode >= 0, mode <= 100_000 {
                let state = privateMode ? privateModeState(mode) : ansiModeState(mode)
                respond("\u{1b}[\(privateMode ? "?" : "")\(mode);\(state)$y")
            }
            return
        }
        if prefix == ">" {
            if final == 99, values == [0] { respond("\u{1b}[>0;0;0c") }
            return
        }
        if prefix == "?" {
            guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ";") }) else { return }
            if final == 104 || final == 108 {
                for mode in values { setPrivateMode(mode, enabled: final == 104) }
            } else if final == 110, values == [6] {
                respond("\u{1b}[?\(reportedCursorRow);\(cursorColumn + 1)R")
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
            else if values == [6] { respond("\u{1b}[\(reportedCursorRow);\(cursorColumn + 1)R") }
        case 99:
            if values == [0] { respond("\u{1b}[?1;2c") }
        case 65: moveVertically(by: -value(), column: cursorColumn)
        case 66, 101: moveVertically(by: value(), column: cursorColumn)
        case 67, 97: move(row: cursorRow, column: cursorColumn + value())
        case 68: move(row: cursorRow, column: cursorColumn - value())
        case 69: moveVertically(by: value(), column: 0)
        case 70: moveVertically(by: -value(), column: 0)
        case 71, 96: move(row: cursorRow, column: value() - 1)
        case 100: address(row: value() - 1, column: cursorColumn)
        case 72, 102: address(row: value() - 1, column: value(1) - 1)
        case 73: tab(by: value())
        case 90: tab(by: -value())
        case 103:
            if values == [0] { tabStops.remove(cursorColumn) }
            else if values == [3] { tabStops.removeAll() }
        case 104, 108:
            for mode in values {
                if mode == 4 { insertMode = final == 104 }
                if mode == 20 { lineFeedNewLine = final == 104 }
            }
        case 98:
            if let text = lastGraphic {
                for _ in 0..<min(4096, value()) {
                    for scalar in text.unicodeScalars { put(scalar) }
                }
            }
        case 74:
            wrapPending = false; lastPrinted = nil
            switch values.first ?? 0 {
            case 1:
                for row in 0..<cursorRow { grid[row] = blankLine() }
                for column in 0...cursorColumn { clearCell(row: cursorRow, column: column) }
            case 2: grid = Array(repeating: blankLine(), count: rows)
            case 3: scrollback.removeAll()
            case 0:
                for column in cursorColumn..<columns { clearCell(row: cursorRow, column: column) }
                grid[cursorRow].wrappedColumns = nil
                if cursorRow + 1 < rows { for row in (cursorRow + 1)..<rows { grid[row] = blankLine() } }
            default: break
            }
        case 75:
            wrapPending = false; lastPrinted = nil
            let mode = values.first ?? 0
            guard (0...2).contains(mode) else { return }
            let range = mode == 1 ? 0...cursorColumn : mode == 2 ? 0...(columns - 1) : cursorColumn...(columns - 1)
            for column in range { clearCell(row: cursorRow, column: column) }
            if mode != 1 { grid[cursorRow].wrappedColumns = nil }
        case 64:
            wrapPending = false; lastPrinted = nil
            insertCells(min(value(), columns - cursorColumn))
        case 80:
            wrapPending = false; lastPrinted = nil
            let count = min(value(), columns - cursorColumn)
            grid[cursorRow].cells.removeSubrange(cursorColumn..<(cursorColumn + count))
            grid[cursorRow].cells += Array(repeating: blankCell(), count: count)
            Self.normalize(&grid[cursorRow].cells)
        case 88:
            wrapPending = false; lastPrinted = nil
            for column in cursorColumn..<min(columns, cursorColumn + value()) { clearCell(row: cursorRow, column: column) }
        case 76:
            if (scrollTop...scrollBottom).contains(cursorRow) {
                wrapPending = false; lastPrinted = nil
                for _ in 0..<min(value(), scrollBottom - cursorRow + 1) { grid.remove(at: scrollBottom); grid.insert(blankLine(), at: cursorRow) }
            }
        case 77:
            if (scrollTop...scrollBottom).contains(cursorRow) {
                wrapPending = false; lastPrinted = nil
                for _ in 0..<min(value(), scrollBottom - cursorRow + 1) { grid.remove(at: cursorRow); grid.insert(blankLine(), at: scrollBottom) }
            }
        case 83: for _ in 0..<min(rows, value()) { let saved = cursorRow; cursorRow = scrollBottom; lineFeed(); cursorRow = saved }
        case 84: for _ in 0..<min(rows, value()) { let saved = cursorRow; cursorRow = scrollTop; reverseIndex(); cursorRow = saved }
        case 114:
            let top = value() - 1, bottom = value(1, default: rows) - 1
            if top >= 0 && top <= bottom && bottom < rows && (top < bottom || rows == 1) {
                scrollTop = top; scrollBottom = bottom; address(row: 0, column: 0)
            }
        case 115: saveCursor()
        case 117: restoreCursor()
        case 116: windowReport(values)
        default: break // Unsupported device queries never leak into text.
        }
    }
    private var reportedCursorRow: Int { cursorRow + 1 - (originMode ? scrollTop : 0) }

    private mutating func address(row: Int, column: Int) {
        move(row: originMode ? min(scrollBottom, scrollTop + row) : row, column: column)
    }

    private mutating func moveVertically(by distance: Int, column: Int) {
        let inMargins = (scrollTop...scrollBottom).contains(cursorRow)
        let top = inMargins ? scrollTop : 0
        let bottom = inMargins ? scrollBottom : rows - 1
        move(row: min(bottom, max(top, cursorRow + distance)), column: column)
    }

    private mutating func setPrivateMode(_ mode: Int, enabled: Bool) {
        switch mode {
        case 1: applicationCursorKeys = enabled
        case 5: reverseVideo = enabled
        case 6: originMode = enabled; address(row: 0, column: 0)
        case 7: autoWrap = enabled; if !enabled { wrapPending = false }
        case 9, 1000, 1002, 1003:
            let tracking = mouseTrackingMode(mode)
            if enabled { mouseReporting.tracking = tracking }
            else if mouseReporting.tracking == tracking { mouseReporting.tracking = .off }
        case 12:
            switch cursorShape {
            case .defaultBlock, .blinkBlock, .steadyBlock: cursorShape = enabled ? .blinkBlock : .steadyBlock
            case .blinkUnderline, .steadyUnderline: cursorShape = enabled ? .blinkUnderline : .steadyUnderline
            case .blinkBar, .steadyBar: cursorShape = enabled ? .blinkBar : .steadyBar
            }
        case 25: cursorVisible = enabled
        case 47, 1047, 1049:
            if enabled { enterAlternateScreen(clearing: mode == 1049) }
            else { leaveAlternateScreen(clearing: mode == 1047, restoreCursor: mode == 1049) }
        case 66: applicationKeypad = enabled
        case 1004: focusReportingEnabled = enabled
        case 1005, 1006, 1015, 1016:
            let encoding = mouseEncodingMode(mode)
            if enabled { mouseReporting.encoding = encoding }
            else if mouseReporting.encoding == encoding { mouseReporting.encoding = .legacy }
        case 1007: alternateScrollEnabled = enabled
        case 1048: if enabled { saveCursor() } else { restoreCursor() }
        case 2004: bracketedPasteEnabled = enabled
        default: break
        }
    }

    private func mouseTrackingMode(_ mode: Int) -> TerminalMouseReporting.Tracking {
        switch mode {
        case 9: return .press
        case 1000: return .normal
        case 1002: return .drag
        default: return .all
        }
    }

    private func mouseEncodingMode(_ mode: Int) -> TerminalMouseReporting.Encoding {
        switch mode {
        case 1005: return .utf8
        case 1006: return .sgr
        case 1015: return .urxvt
        default: return .sgrPixels
        }
    }

    private func ansiModeState(_ mode: Int) -> Int {
        switch mode {
        case 4: return insertMode ? 1 : 2
        case 20: return lineFeedNewLine ? 1 : 2
        default: return 0
        }
    }

    private func privateModeState(_ mode: Int) -> Int {
        let state: Bool
        switch mode {
        case 1: state = applicationCursorKeys
        case 5: state = reverseVideo
        case 6: state = originMode
        case 7: state = autoWrap
        case 9, 1000, 1002, 1003: state = mouseReporting.tracking == mouseTrackingMode(mode)
        case 25: state = cursorVisible
        case 47, 1047, 1049: state = isAlternateScreen
        case 66: state = applicationKeypad
        case 1004: state = focusReportingEnabled
        case 1005, 1006, 1015, 1016: state = mouseReporting.encoding == mouseEncodingMode(mode)
        case 1007: state = alternateScrollEnabled
        case 2004: state = bracketedPasteEnabled
        default: return 0
        }
        return state ? 1 : 2
    }

    private mutating func enterAlternateScreen(clearing: Bool) {
        guard alternate == nil else { return }
        alternate = Snapshot(grid: grid, row: cursorRow, column: cursorColumn, scrollback: scrollback,
                             attributes: attributes, savedCursor: savedCursor, wrapPending: wrapPending,
                             scrollTop: scrollTop, scrollBottom: scrollBottom, originMode: originMode,
                             autoWrap: autoWrap, restoreCursorOnExit: clearing,
                             g0Graphics: g0Graphics, g1Graphics: g1Graphics, useG1: useG1)
        grid = clearing ? Array(repeating: blankLine(), count: rows) : alternateGrid ?? Array(repeating: blankLine(), count: rows)
        alternateGrid = nil; scrollback = []
        savedCursor = alternateSavedCursor
        if clearing {
            scrollTop = 0; scrollBottom = rows - 1; originMode = false
            move(row: 0, column: 0)
        }
    }

    private mutating func leaveAlternateScreen(clearing: Bool = false, restoreCursor: Bool? = nil) {
        guard let previous = alternate else { return }
        alternateGrid = clearing ? nil : grid
        alternateSavedCursor = clearing ? SavedCursor() : savedCursor
        grid = previous.grid; scrollback = previous.scrollback
        savedCursor = previous.savedCursor
        if restoreCursor ?? previous.restoreCursorOnExit {
            move(row: previous.row, column: previous.column)
            attributes = previous.attributes; wrapPending = previous.wrapPending
            scrollTop = previous.scrollTop; scrollBottom = previous.scrollBottom
            originMode = previous.originMode; autoWrap = previous.autoWrap
            g0Graphics = previous.g0Graphics; g1Graphics = previous.g1Graphics; useG1 = previous.useG1
        } else {
            lastPrinted = nil; wrapPending = false
        }
        alternate = nil
    }

    private mutating func saveCursor() {
        savedCursor = SavedCursor(row: cursorRow, column: cursorColumn, attributes: attributes,
                                  wrapPending: wrapPending, originMode: originMode, autoWrap: autoWrap,
                                  g0Graphics: g0Graphics, g1Graphics: g1Graphics, useG1: useG1)
    }

    private mutating func restoreCursor() {
        move(row: savedCursor.row, column: savedCursor.column)
        attributes = savedCursor.attributes; wrapPending = savedCursor.wrapPending
        originMode = savedCursor.originMode; autoWrap = savedCursor.autoWrap
        g0Graphics = savedCursor.g0Graphics; g1Graphics = savedCursor.g1Graphics; useG1 = savedCursor.useG1
    }

    private mutating func softReset() {
        resetInputModes()
        attributes = TerminalAttributes(); cursorShape = .defaultBlock
        originMode = false; autoWrap = true; insertMode = false; lineFeedNewLine = false
        g0Graphics = false; g1Graphics = false; useG1 = false
        savedCursor = SavedCursor(); wrapPending = false
        scrollTop = 0; scrollBottom = rows - 1; lastPrinted = nil
    }

    private mutating func reset() {
        softReset()
        reverseVideo = false; palette.removeAll(); defaultForeground = nil; defaultBackground = nil; cursorColor = nil
        title = nil; iconTitle = nil; titles.removeAll(); reportedWorkingDirectory = nil; lastGraphic = nil
        tabStops = Set(stride(from: 8, to: columns, by: 8))
        responses.removeAll(keepingCapacity: true)
        grid = Array(repeating: blankLine(), count: rows); scrollback.removeAll()
        alternate = nil; alternateGrid = nil; alternateSavedCursor = SavedCursor()
        move(row: 0, column: 0)
    }

    private mutating func windowReport(_ values: [Int]) {
        switch values.first {
        case 18: respond("\u{1b}[8;\(rows);\(columns)t")
        case 22:
            if titles.count == 16 { titles.removeFirst() }
            titles.append((title, iconTitle))
        case 23:
            if let entry = titles.popLast() {
                if values.count < 2 || values[1] != 1 { title = entry.title }
                if values.count < 2 || values[1] != 2 { iconTitle = entry.icon }
            }
        default: break
        }
    }

    private mutating func respond(_ text: String) {
        let bytes = Data(text.utf8)
        if responses.count + bytes.count <= 4096 { responses.append(bytes) }
    }

    private mutating func finishDCS() {
        let query = String(decoding: sequence, as: UTF8.self)
        guard query.hasPrefix("$q") else { return }
        let value: String?
        switch query.dropFirst(2) {
        case "r": value = "\(scrollTop + 1);\(scrollBottom + 1)r"
        case " q": value = "\(cursorShape.rawValue) q"
        case "m": value = sgrStatus()
        default: value = nil
        }
        if let value { respond("\u{1b}P1$r\(value)\u{1b}\\") }
        else { respond("\u{1b}P0$r\u{1b}\\") }
    }

    private func sgrStatus() -> String {
        var fields = [0]
        if attributes.bold { fields.append(1) }
        if attributes.faint { fields.append(2) }
        if attributes.italic { fields.append(3) }
        if attributes.underline { fields.append(4) }
        if attributes.inverse { fields.append(7) }
        if attributes.hidden { fields.append(8) }
        if attributes.strikethrough { fields.append(9) }
        func appendColor(_ color: TerminalColor?, slot: Int) {
            switch color {
            case let .indexed(index): fields += [slot, 5, Int(index)]
            case let .rgb(r, g, b): fields += [slot, 2, Int(r), Int(g), Int(b)]
            case nil: break
            }
        }
        appendColor(attributes.foreground, slot: 38)
        appendColor(attributes.background, slot: 48)
        return fields.map(String.init).joined(separator: ";") + "m"
    }

    private mutating func finishOSC() {
        defer { osc.removeAll(keepingCapacity: true); oscOverflow = false }
        guard !oscOverflow, let source = String(bytes: osc, encoding: .utf8) else { return }
        let fields = source.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let command = fields.first else { return }
        let payload = fields.count == 2 ? String(fields[1]) : ""
        guard !payload.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else { return }
        switch command {
        case "0", "1", "2":
            if payload.utf8.count <= 1024 {
                if command != "1" { title = payload }
                if command != "2" { iconTitle = payload }
            }
        case "4":
            let entries = payload.split(separator: ";", omittingEmptySubsequences: false)
            for index in stride(from: 0, to: entries.count - entries.count % 2, by: 2) {
                guard let color = UInt8(entries[index]) else { continue }
                let spec = String(entries[index + 1])
                if spec == "?" { reportColor("4;\(color)", palette[color] ?? .indexed(color)) }
                else if let value = TerminalColor(osc: spec) { palette[color] = value }
            }
        case "104":
            if payload.isEmpty { palette.removeAll() }
            else { for field in payload.split(separator: ";") { if let color = UInt8(field) { palette.removeValue(forKey: color) } } }
        case "10", "11", "12":
            guard let start = Int(command) else { return }
            for (offset, field) in payload.split(separator: ";", omittingEmptySubsequences: false).prefix(13 - start).enumerated() {
                applyDynamicColor(start + offset, spec: String(field))
            }
        case "110": defaultForeground = nil
        case "111": defaultBackground = nil
        case "112": cursorColor = nil
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

    private mutating func reportColor(_ command: String, _ color: TerminalColor) {
        respond("\u{1b}]\(command);\(color.oscDescription)\u{1b}\\")
    }

    private mutating func applyDynamicColor(_ slot: Int, spec: String) {
        if spec == "?" {
            let color: TerminalColor
            switch slot {
            case 10: color = defaultForeground ?? hostForeground
            case 11: color = defaultBackground ?? hostBackground
            default: color = cursorColor ?? defaultForeground ?? hostForeground
            }
            reportColor(String(slot), color)
        } else if let color = TerminalColor(osc: spec) {
            switch slot {
            case 10: defaultForeground = color
            case 11: defaultBackground = color
            default: cursorColor = color
            }
        }
    }

    private mutating func applySGR(_ source: String) {
        if source.isEmpty { attributes = TerminalAttributes(); return }
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
    private func blankLine() -> Row { Row(cells: Array(repeating: blankCell(), count: columns)) }
}
