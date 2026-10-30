import Foundation

public struct EditorSearchQuery: Equatable, Sendable {
    public var pattern: String
    public var regex: Bool
    public var caseSensitive: Bool
    public var wholeWords: Bool

    public init(pattern: String, regex: Bool = false, caseSensitive: Bool = false, wholeWords: Bool = false) {
        self.pattern = pattern; self.regex = regex
        self.caseSensitive = caseSensitive; self.wholeWords = wholeWords
    }
}

public struct EditorEdit: Equatable, Sendable {
    public let text: String
    public let selection: NSRange
    public let count: Int

    public init(text: String, selection: NSRange, count: Int) {
        self.text = text; self.selection = selection; self.count = count
    }
}

public enum EditorEditingError: Error, LocalizedError, Equatable {
    case emptyQuery, queryTooLong, unsupportedMultilineRegex
    case invalidRegularExpression(String)
    case regexLineTooLong(offset: Int), regexDeadlineExceeded, regexExecutionFailed
    case invalidRange, invalidPosition, rangeDoesNotMatch, operationTooLarge, invalidRectangleCoordinate

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: return "Введите строку поиска."
        case .queryTooLong: return "Предел строки поиска — 4096 символов."
        case .unsupportedMultilineRegex: return "Регулярные выражения проверяются в пределах одной строки."
        case .invalidRegularExpression(let reason): return "Некорректное регулярное выражение: \(reason)"
        case .regexLineTooLong(let offset): return "Поиск неполон: строка с позиции \(offset) превышает 1 МиБ."
        case .regexDeadlineExceeded: return "Поиск неполон: превышено время проверки регулярного выражения (50 мс на строку)."
        case .regexExecutionFailed: return "Поиск неполон: ошибка выполнения регулярного выражения."
        case .invalidRange: return "Выделение находится за пределами текста или разрывает символ."
        case .invalidPosition: return "Указанная строка или колонка находится за пределами текста."
        case .rangeDoesNotMatch: return "Выделенный текст больше не соответствует строке поиска."
        case .operationTooLarge: return "Операция превышает предел: 16 МиБ текста UTF-16 или 100 000 замен/строк блока."
        case .invalidRectangleCoordinate: return "Координаты блока должны быть от 1 до 1 000 000."
        }
    }
}

/// A rectangular block uses inclusive, 1-based line numbers and a half-open visual-column
/// interval. Each extended grapheme occupies one cell; a tab extends to the next tab stop.
/// This deliberately does not infer terminal glyph widths. Partial tabs are copied/edited as
/// spaces; other graphemes are never split. Reversed coordinates are normalized. Coordinates
/// must lie in 1...1,000,000, with at most 100,000 selected or appended rows.
public struct EditorRectangle: Equatable, Sendable {
    public var firstLine: Int
    public var lastLine: Int
    public var firstColumn: Int
    public var lastColumn: Int

    public init(firstLine: Int, lastLine: Int, firstColumn: Int, lastColumn: Int) {
        self.firstLine = firstLine; self.lastLine = lastLine
        self.firstColumn = firstColumn; self.lastColumn = lastColumn
    }
}

/// Foundation-only operations. Offsets and result selections are UTF-16, suitable for
/// NSTextView. Regex evaluation is per logical line, with a 1 MiB UTF-8 line cap and a
/// cooperative ICU progress deadline of 50 ms per examined line. ICU's callbacks are not a
/// hard real-time interruption guarantee: callers must run searches off the main thread.
/// Forward search includes `from`, backward search requires a start strictly before it.
/// Searches never wrap. Repeat an empty forward result after its next Unicode scalar.
/// Editing operations cap output at 16 Mi UTF-16 units and replacements/selected rows at
/// 100,000. They throw before committing any text; regex-template sizing is conservative.
public enum EditorEditing {
    public static let maximumRegexLineBytes = 1_048_576
    public static let maximumOutputUTF16 = 16 * 1_048_576
    public static let maximumMatches = 100_000
    public static let maximumRectangleCoordinate = 1_000_000

    public static func validate(_ query: EditorSearchQuery) throws { _ = try EditorSearchPlan(query) }

    public static func find(in text: String, query: EditorSearchQuery, from: Int,
                            direction: ViewerSearchDirection = .forward) throws -> NSRange? {
        let plan = try EditorSearchPlan(query)
        let source = text as NSString
        let origin = min(max(0, from), source.length)
        if direction == .backward, origin == 0 { return nil }
        if !query.regex { return literalFind(text, plan: plan, from: origin, direction: direction) }
        var latest: NSRange?
        for line in EditorLine.table(text) {
            if direction == .forward, line.end < origin { continue }
            if direction == .backward, line.start >= origin { break }
            let value = source.substring(with: line.range)
            try checkLine(value, offset: line.start)
            let beginning = direction == .forward ? scalarBoundary(value, at: max(0, origin - line.start), forward: true) : 0
            let deadline = ProcessInfo.processInfo.systemUptime + 0.05
            var cursor = beginning
            while cursor <= line.range.length {
                guard let match = try regexFirst(value, plan: plan, from: cursor, deadline: deadline) else { break }
                let range = NSRange(location: line.start + match.range.location, length: match.range.length)
                if direction == .forward { return range }
                if range.location >= origin { break }
                latest = range
                // Advancing from the start retains overlapping backward matches.
                if match.range.location == line.range.length { break }
                cursor = scalarBoundary(value, at: match.range.location + 1, forward: true)
            }
        }
        return latest
    }

    public static func replace(in text: String, range: NSRange, query: EditorSearchQuery,
                               replacement: String) throws -> String {
        let plan = try EditorSearchPlan(query)
        guard validRange(range, in: text) else { throw EditorEditingError.invalidRange }
        let source = text as NSString
        let inserted: String
        if query.regex {
            guard let line = EditorLine.table(text).first(where: { range.location >= $0.start && NSMaxRange(range) <= $0.end })
            else { throw EditorEditingError.rangeDoesNotMatch }
            let value = source.substring(with: line.range)
            try checkLine(value, offset: line.start)
            guard let match = try regexFirst(value, plan: plan, from: range.location - line.start,
                                             deadline: ProcessInfo.processInfo.systemUptime + 0.05),
                  match.range == NSRange(location: range.location - line.start, length: range.length)
            else { throw EditorEditingError.rangeDoesNotMatch }
            let remaining = maximumOutputUTF16 - (source.length - range.length)
            inserted = try expandedReplacement(replacement, match: match, value: value, plan: plan, remaining: remaining)
        } else {
            guard literalFind(text, plan: plan, from: range.location, direction: .forward) == range
            else { throw EditorEditingError.rangeDoesNotMatch }
            inserted = replacement
        }
        try checkOutput(base: source.length - range.length, inserted: inserted.utf16.count)
        return source.replacingCharacters(in: range, with: inserted)
    }

    public static func replaceAll(in text: String, query: EditorSearchQuery,
                                  replacement: String) throws -> EditorEdit {
        let plan = try EditorSearchPlan(query)
        let source = text as NSString
        guard source.length <= maximumOutputUTF16 else { throw EditorEditingError.operationTooLarge }
        var projectedLength = source.length
        var changes = [(NSRange, String)]()
        func append(_ range: NSRange, _ inserted: String) throws {
            guard changes.count < maximumMatches else { throw EditorEditingError.operationTooLarge }
            try checkOutput(base: projectedLength - range.length, inserted: inserted.utf16.count)
            projectedLength += inserted.utf16.count - range.length
            changes.append((range, inserted))
        }
        if query.regex {
            for line in EditorLine.table(text) {
                let value = source.substring(with: line.range)
                try checkLine(value, offset: line.start)
                let deadline = ProcessInfo.processInfo.systemUptime + 0.05
                var cursor = 0
                while cursor <= line.range.length {
                    guard let match = try regexFirst(value, plan: plan, from: cursor, deadline: deadline) else { break }
                    guard changes.count < maximumMatches else { throw EditorEditingError.operationTooLarge }
                    let remaining = maximumOutputUTF16 - (projectedLength - match.range.length)
                    let inserted = try expandedReplacement(replacement, match: match, value: value, plan: plan, remaining: remaining)
                    try append(NSRange(location: line.start + match.range.location, length: match.range.length), inserted)
                    cursor = NSMaxRange(match.range)
                    if match.range.length == 0 {
                        if cursor == line.range.length { break }
                        cursor = scalarBoundary(value, at: cursor + 1, forward: true)
                    }
                }
            }
        } else {
            var cursor = 0
            while let match = literalFind(text, plan: plan, from: cursor, direction: .forward) {
                try append(match, replacement); cursor = NSMaxRange(match)
            }
        }
        guard let finalChange = changes.last else {
            return EditorEdit(text: text, selection: NSRange(location: 0, length: 0), count: 0)
        }
        let result = NSMutableString(string: text)
        for (range, inserted) in changes.reversed() { result.replaceCharacters(in: range, with: inserted) }
        let shift = changes.dropLast().reduce(0) { $0 + $1.1.utf16.count - $1.0.length }
        return EditorEdit(text: result as String,
                          selection: NSRange(location: finalChange.0.location + shift, length: finalChange.1.utf16.count),
                          count: changes.count)
    }

    /// Columns count Unicode scalars, not UTF-16 code units or visual tab cells. A UTF-16
    /// offset inside a surrogate pair resolves to that scalar's beginning; CRLF is one EOL.
    public static func lineColumn(in text: String, offset: Int) -> (line: Int, column: Int) {
        let source = text as NSString
        let clamped = scalarBoundary(text, at: min(max(0, offset), source.length), forward: false)
        let lines = EditorLine.table(text)
        let index = lines.lastIndex(where: { $0.start <= clamped }) ?? 0
        let line = lines[index]
        let prefix = source.substring(with: NSRange(location: line.start, length: min(clamped, line.end) - line.start))
        return (index + 1, prefix.unicodeScalars.count + 1)
    }

    public static func offset(in text: String, line: Int, column: Int = 1) throws -> Int {
        let lines = EditorLine.table(text)
        guard line > 0, line <= lines.count, column > 0 else { throw EditorEditingError.invalidPosition }
        let value = (text as NSString).substring(with: lines[line - 1].range)
        guard column <= value.unicodeScalars.count + 1 else { throw EditorEditingError.invalidPosition }
        let prefix = value.unicodeScalars.prefix(column - 1)
        return lines[line - 1].start + prefix.reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
    }

    /// A selection ending exactly at the next line's start excludes that next line.
    /// Empty selections preserve the caret; nonempty selections remain around their text.
    public static func indent(in text: String, selection: NSRange, tabSize: Int,
                              useSpaces: Bool, outdent: Bool = false) throws -> EditorEdit {
        let source = text as NSString
        guard source.length <= maximumOutputUTF16 else { throw EditorEditingError.operationTooLarge }
        let selection = clampedRange(selection, in: text)
        let lines = EditorLine.table(text)
        let size = min(256, max(1, tabSize))
        let lastPosition = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let firstIndex = lines.lastIndex(where: { $0.start <= selection.location }) ?? 0
        let lastIndex = lines.lastIndex(where: { $0.start <= lastPosition }) ?? firstIndex
        let affected = lines[firstIndex...max(firstIndex, lastIndex)]
        guard affected.count <= maximumMatches else { throw EditorEditingError.operationTooLarge }
        let insertedPerLine = useSpaces ? size : 1
        if !outdent, affected.count > (maximumOutputUTF16 - source.length) / insertedPerLine {
            throw EditorEditingError.operationTooLarge
        }
        var changes = [(NSRange, String)]()
        for line in affected {
            if outdent {
                let value = source.substring(with: line.range)
                var length = 0
                for character in value {
                    if character == "\t", length == 0 { length = 1; break }
                    guard character == " ", length < size else { break }
                    length += 1
                }
                if length > 0 { changes.append((NSRange(location: line.start, length: length), "")) }
            } else {
                changes.append((NSRange(location: line.start, length: 0), useSpaces ? String(repeating: " ", count: size) : "\t"))
            }
        }
        let result = NSMutableString(string: text)
        for (range, inserted) in changes.reversed() { result.replaceCharacters(in: range, with: inserted) }
        func transform(_ offset: Int) -> Int {
            var transformed = offset
            for (range, inserted) in changes {
                if offset >= NSMaxRange(range) { transformed += inserted.utf16.count - range.length }
                else if offset > range.location { transformed -= offset - range.location }
            }
            return transformed
        }
        let start = transform(selection.location)
        let end = transform(NSMaxRange(selection))
        return EditorEdit(text: result as String, selection: NSRange(location: start, length: max(0, end - start)), count: changes.count)
    }

    public static func extractRectangle(in text: String, rectangle: EditorRectangle, tabSize: Int) throws -> String {
        try checkRectangle(rectangle, text: text)
        let rectangle = normalized(rectangle)
        let source = text as NSString
        let lines = EditorLine.table(text)
        guard rectangle.firstLine <= lines.count else { return "" }
        var output = ""
        for number in rectangle.firstLine...min(rectangle.lastLine, lines.count) {
            let value = source.substring(with: lines[number - 1].range)
            let row = visualSlice(value, lower: rectangle.firstColumn - 1, upper: rectangle.lastColumn - 1, tabSize: tabSize)
            try checkOutput(base: output.utf16.count, inserted: row.utf16.count + (number == rectangle.firstLine ? 0 : 1))
            if number > rectangle.firstLine { output += "\n" }
            output += row
        }
        return output
    }

    /// One replacement row repeats on each selected line; multiple rows map one-to-one,
    /// and missing rows mean deletion. Extra rows extend the rectangle downwards (and may
    /// append lines). Short existing lines are padded only when their replacement is nonempty.
    /// Existing line endings are preserved; appended lines use the document's first EOL.
    public static func replaceRectangle(in text: String, rectangle: EditorRectangle,
                                        replacement: String, tabSize: Int) throws -> EditorEdit {
        try checkRectangle(rectangle, text: text)
        guard replacement.utf16.count <= maximumOutputUTF16 else { throw EditorEditingError.operationTooLarge }
        let rectangle = normalized(rectangle)
        let source = text as NSString
        let lines = EditorLine.table(text)
        let replacementLines = EditorLine.table(replacement).map { (replacement as NSString).substring(with: $0.range) }
        if replacement.isEmpty, rectangle.firstColumn == rectangle.lastColumn || rectangle.firstLine > lines.count {
            return EditorEdit(text: text, selection: NSRange(location: source.length, length: 0), count: 0)
        }
        let count = max(rectangle.lastLine - rectangle.firstLine + 1, replacementLines.count)
        guard count <= maximumMatches else { throw EditorEditingError.operationTooLarge }
        let finalLine = replacement.isEmpty ? min(lines.count, rectangle.firstLine + count - 1) : rectangle.firstLine + count - 1
        guard finalLine <= maximumRectangleCoordinate, finalLine - lines.count <= maximumMatches else { throw EditorEditingError.operationTooLarge }
        let eol = lines.first(where: { $0.next > $0.end }).map {
            source.substring(with: NSRange(location: $0.end, length: $0.next - $0.end))
        } ?? "\n"
        var output = [String]()
        var selectionStart: Int?
        var selectionEnd = 0
        var length = 0
        var changed = 0
        for number in 1...max(lines.count, finalLine) {
            let line = number <= lines.count ? lines[number - 1] : nil
            var value = line.map { source.substring(with: $0.range) } ?? ""
            if number >= rectangle.firstLine, number <= finalLine {
                let row = number - rectangle.firstLine
                let inserted = replacementLines.count == 1 ? replacementLines[0]
                    : (row < replacementLines.count ? replacementLines[row] : "")
                let prefixLength = visualPrefixLength(value, through: rectangle.firstColumn - 1, tabSize: tabSize, pad: !inserted.isEmpty)
                let suffixLength = visualSuffixLength(value, from: rectangle.lastColumn - 1, tabSize: tabSize)
                try checkOutput(base: length, inserted: prefixLength + inserted.utf16.count + suffixLength)
                let prefix = visualPrefix(value, through: rectangle.firstColumn - 1, tabSize: tabSize, pad: !inserted.isEmpty)
                let suffix = visualSuffix(value, from: rectangle.lastColumn - 1, tabSize: tabSize)
                let updated = prefix + inserted + suffix
                if updated != value { changed += 1 }
                value = updated
                if selectionStart == nil { selectionStart = length + prefix.utf16.count }
                selectionEnd = length + prefix.utf16.count + inserted.utf16.count
            }
            let ending: String
            if let line, line.next > line.end { ending = source.substring(with: NSRange(location: line.end, length: line.next - line.end)) }
            else { ending = number < max(lines.count, finalLine) ? eol : "" }
            try checkOutput(base: length, inserted: value.utf16.count + ending.utf16.count)
            output.append(value + ending); length += value.utf16.count + ending.utf16.count
        }
        let start = selectionStart ?? min(source.length, length)
        return EditorEdit(text: output.joined(), selection: NSRange(location: start, length: max(0, selectionEnd - start)), count: changed)
    }

    private static func normalized(_ rectangle: EditorRectangle) -> EditorRectangle {
        EditorRectangle(firstLine: max(1, min(rectangle.firstLine, rectangle.lastLine)),
                        lastLine: max(1, max(rectangle.firstLine, rectangle.lastLine)),
                        firstColumn: max(1, min(rectangle.firstColumn, rectangle.lastColumn)),
                        lastColumn: max(1, max(rectangle.firstColumn, rectangle.lastColumn)))
    }

    private static func checkOutput(base: Int, inserted: Int) throws {
        guard base >= 0, base <= maximumOutputUTF16, inserted >= 0, inserted <= maximumOutputUTF16 - base
        else { throw EditorEditingError.operationTooLarge }
    }

    private static func checkRectangle(_ rectangle: EditorRectangle, text: String) throws {
        let coordinates = [rectangle.firstLine, rectangle.lastLine, rectangle.firstColumn, rectangle.lastColumn]
        guard coordinates.allSatisfy({ $0 > 0 && $0 <= maximumRectangleCoordinate })
        else { throw EditorEditingError.invalidRectangleCoordinate }
        guard abs(rectangle.lastLine - rectangle.firstLine) < maximumMatches,
              text.utf16.count <= maximumOutputUTF16 else { throw EditorEditingError.operationTooLarge }
    }

    private static func expandedReplacement(_ template: String, match: NSTextCheckingResult, value: String,
                                            plan: EditorSearchPlan, remaining: Int) throws -> String {
        // Bound before Foundation expands captures. Counting every dollar as the longest
        // capture is conservative (also for escaped dollars), but avoids allocating an
        // enormous intermediate replacement before the caller can inspect its length.
        let templateLength = template.utf16.count
        guard remaining >= 0, templateLength <= remaining else { throw EditorEditingError.operationTooLarge }
        let dollars = template.utf16.reduce(0) { $0 + ($1 == 36 ? 1 : 0) }
        let longest = (0..<match.numberOfRanges).map { match.range(at: $0) }.filter { $0.location != NSNotFound }.map(\.length).max() ?? 0
        if dollars > 0, longest > 0, dollars > (remaining - templateLength) / longest {
            throw EditorEditingError.operationTooLarge
        }
        let inserted = plan.expression!.replacementString(for: match, in: value, offset: 0, template: template)
        guard inserted.utf16.count <= remaining else { throw EditorEditingError.operationTooLarge }
        return inserted
    }

    private static func visualCells(_ text: String, tabSize: Int, body: (String, Int, Int) -> Void) {
        let size = min(256, max(1, tabSize))
        var column = 0
        for character in text {
            let end = character == "\t" ? column + size - column % size : column + 1
            body(String(character), column, end); column = end
        }
    }

    private static func visualSlice(_ text: String, lower: Int, upper: Int, tabSize: Int) -> String {
        var output = ""
        visualCells(text, tabSize: tabSize) { value, start, end in
            let overlap = min(end, upper) - max(start, lower)
            if overlap > 0 { output += value == "\t" ? String(repeating: " ", count: overlap) : value }
        }
        return output
    }

    private static func visualPrefix(_ text: String, through column: Int, tabSize: Int, pad: Bool) -> String {
        var output = ""
        var finalColumn = 0
        visualCells(text, tabSize: tabSize) { value, start, end in
            if start < column { output += end <= column ? value : String(repeating: " ", count: column - start) }
            finalColumn = end
        }
        if pad { output += String(repeating: " ", count: max(0, column - finalColumn)) }
        return output
    }

    private static func visualSuffix(_ text: String, from column: Int, tabSize: Int) -> String {
        var output = ""
        visualCells(text, tabSize: tabSize) { value, start, end in
            if end > column { output += start >= column ? value : String(repeating: " ", count: end - column) }
        }
        return output
    }

    private static func visualPrefixLength(_ text: String, through column: Int, tabSize: Int, pad: Bool) -> Int {
        var length = 0
        var finalColumn = 0
        visualCells(text, tabSize: tabSize) { value, start, end in
            if start < column { length += end <= column ? value.utf16.count : column - start }
            finalColumn = end
        }
        return length + (pad ? max(0, column - finalColumn) : 0)
    }

    private static func visualSuffixLength(_ text: String, from column: Int, tabSize: Int) -> Int {
        var length = 0
        visualCells(text, tabSize: tabSize) { value, start, end in
            if end > column { length += start >= column ? value.utf16.count : end - column }
        }
        return length
    }

    private static func checkLine(_ line: String, offset: Int) throws {
        guard line.utf8.count <= maximumRegexLineBytes else { throw EditorEditingError.regexLineTooLong(offset: offset) }
    }

    private static func regexFirst(_ text: String, plan: EditorSearchPlan, from: Int, deadline: TimeInterval) throws -> NSTextCheckingResult? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw EditorEditingError.regexDeadlineExceeded }
        var result: NSTextCheckingResult?
        var timedOut = false
        var failed = false
        plan.expression!.enumerateMatches(in: text,
            options: [.reportProgress, .reportCompletion, .withoutAnchoringBounds, .withTransparentBounds],
            range: NSRange(location: from, length: text.utf16.count - from)) { match, flags, stop in
                if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; stop.pointee = true }
                else if flags.contains(.internalError) { failed = true; stop.pointee = true }
                else if let match { result = match; stop.pointee = true }
            }
        if timedOut || ProcessInfo.processInfo.systemUptime >= deadline { throw EditorEditingError.regexDeadlineExceeded }
        if failed { throw EditorEditingError.regexExecutionFailed }
        return result
    }

    private static func literalFind(_ text: String, plan: EditorSearchPlan, from: Int,
                                    direction: ViewerSearchDirection) -> NSRange? {
        let source = text as NSString
        var cursor = direction == .forward ? scalarBoundary(text, at: from, forward: true) : 0
        var latest: NSRange?
        var options: NSString.CompareOptions = [.literal]
        if !plan.query.caseSensitive { options.insert(.caseInsensitive) }
        while cursor <= source.length {
            let found = source.range(of: plan.query.pattern, options: options, range: NSRange(location: cursor, length: source.length - cursor))
            guard found.location != NSNotFound else { break }
            if direction == .backward, found.location >= from { break }
            if !plan.query.wholeWords || isWholeWord(text, range: found) {
                if direction == .forward { return found }
                latest = found
            }
            cursor = scalarBoundary(text, at: found.location + 1, forward: true)
        }
        return latest
    }

    private static func isWholeWord(_ text: String, range: NSRange) -> Bool {
        let source = text as NSString
        let before = source.substring(to: range.location).unicodeScalars.last
        let after = source.substring(from: NSMaxRange(range)).unicodeScalars.first
        func word(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
        }
        return !word(before) && !word(after)
    }

    private static func validRange(_ range: NSRange, in text: String) -> Bool {
        let length = text.utf16.count
        guard range.location >= 0, range.length >= 0, range.location <= length, range.length <= length - range.location else { return false }
        return scalarBoundary(text, at: range.location, forward: false) == range.location
            && scalarBoundary(text, at: NSMaxRange(range), forward: false) == NSMaxRange(range)
    }

    private static func clampedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = text.utf16.count
        let start = scalarBoundary(text, at: min(length, max(0, range.location)), forward: false)
        let remaining = max(0, length - start)
        let end = scalarBoundary(text, at: start + min(remaining, max(0, range.length)), forward: true)
        return NSRange(location: start, length: end - start)
    }

    private static func scalarBoundary(_ text: String, at offset: Int, forward: Bool) -> Int {
        let source = text as NSString
        var offset = min(source.length, max(0, offset))
        if offset > 0, offset < source.length, (0xDC00...0xDFFF).contains(source.character(at: offset)),
           (0xD800...0xDBFF).contains(source.character(at: offset - 1)) { offset += forward ? 1 : -1 }
        return offset
    }
}

private struct EditorLine {
    let start: Int
    let end: Int
    let next: Int
    var range: NSRange { NSRange(location: start, length: end - start) }

    static func table(_ text: String) -> [EditorLine] {
        let units = Array(text.utf16)
        var lines = [EditorLine]()
        var start = 0
        var cursor = 0
        while cursor < units.count {
            if [UInt16(0x0A), 0x0D, 0x85, 0x2028, 0x2029].contains(units[cursor]) {
                let end = cursor
                cursor += units[cursor] == 0x0D && cursor + 1 < units.count && units[cursor + 1] == 0x0A ? 2 : 1
                lines.append(EditorLine(start: start, end: end, next: cursor)); start = cursor
            } else { cursor += 1 }
        }
        lines.append(EditorLine(start: start, end: units.count, next: units.count))
        return lines
    }
}

private struct EditorSearchPlan {
    let query: EditorSearchQuery
    let expression: NSRegularExpression?

    init(_ query: EditorSearchQuery) throws {
        guard !query.pattern.isEmpty else { throw EditorEditingError.emptyQuery }
        guard query.pattern.utf16.count <= 4096 else { throw EditorEditingError.queryTooLong }
        self.query = query
        guard query.regex else { expression = nil; return }
        guard !Self.multiline(query.pattern) else { throw EditorEditingError.unsupportedMultilineRegex }
        let pattern = query.wholeWords ? #"(?<![\p{L}\p{M}\p{N}_])(?:"# + query.pattern + #")(?![\p{L}\p{M}\p{N}_])"# : query.pattern
        do { expression = try NSRegularExpression(pattern: pattern, options: query.caseSensitive ? [] : [.caseInsensitive]) }
        catch { throw EditorEditingError.invalidRegularExpression(error.localizedDescription) }
    }

    private static func multiline(_ pattern: String) -> Bool {
        if pattern.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) { return true }
        let units = Array(pattern.utf16)
        var index = 0
        while index < units.count {
            if units[index] == 92, index + 1 < units.count {
                let token = units[index + 1]
                if [UInt16(110), 114, 82, 65, 90, 122].contains(token) { return true }
                if token == 120 || token == 117 {
                    let tail = String(decoding: units[(index + 2)...].prefix(8), as: UTF16.self).lowercased()
                    let prefixes = token == 120 ? ["0a", "0d", "85", "{a}", "{d}", "{85}", "{2028}", "{2029}"]
                        : ["000a", "000d", "0085", "2028", "2029"]
                    if prefixes.contains(where: { tail.hasPrefix($0) }) { return true }
                }
                index += 2
            } else { index += 1 }
        }
        return pattern.range(of: #"\(\?[A-Za-z-]*[sm]"#, options: .regularExpression) != nil
    }
}
