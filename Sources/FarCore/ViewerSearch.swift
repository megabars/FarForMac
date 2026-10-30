import Foundation

public enum ViewerSearchMode: String, CaseIterable, Sendable {
    case literal, regex, hex
}

public enum ViewerSearchDirection: Sendable { case forward, backward }

public struct ViewerSearchQuery: Sendable {
    public var pattern: String
    public var mode: ViewerSearchMode
    public var caseSensitive: Bool

    public init(pattern: String, mode: ViewerSearchMode = .literal, caseSensitive: Bool = false) {
        self.pattern = pattern; self.mode = mode; self.caseSensitive = caseSensitive
    }
}

public struct ViewerSearchResult: Equatable, Sendable {
    public let byteRange: Range<Int64>
    public init(byteRange: Range<Int64>) { self.byteRange = byteRange }
}

public enum ViewerSearchError: Error, LocalizedError, Equatable {
    case emptyQuery, queryTooLong, invalidHex, unsupportedMultilineRegex
    case invalidRegularExpression(String)
    case regexLineTooLong(offset: Int64), regexDeadlineExceeded, regexExecutionFailed, cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: return "Введите строку поиска."
        case .queryTooLong: return "Предел строки поиска — 4096 символов."
        case .invalidHex: return "Введите пары шестнадцатеричных цифр, например: 48 65 6C 6C 6F."
        case .unsupportedMultilineRegex:
            return "Регулярные выражения проверяются в пределах одной строки; многострочные выражения не поддерживаются."
        case .invalidRegularExpression(let reason): return "Некорректное регулярное выражение: \(reason)"
        case .regexLineTooLong(let offset):
            return "Поиск неполон: строка с позиции \(offset) превышает предел 1 МиБ для регулярных выражений."
        case .regexDeadlineExceeded: return "Поиск неполон: превышено время проверки регулярного выражения (50 мс на строку)."
        case .regexExecutionFailed: return "Поиск неполон: ошибка выполнения регулярного выражения."
        case .cancelled: return "Поиск отменён."
        }
    }
}

/// Bounded-memory search over the viewer's decoded pages, returning original file byte ranges.
/// Forward includes matches starting at `from`; backward requires a start strictly before `from`.
/// Search never wraps. Regex searches logical lines separately (CRLF, CR, LF, NEL, LS, PS),
/// with a 1 MiB source-byte limit per line and a cooperative ICU deadline of 50 ms per line.
/// An unexamined line or interrupted regex throws; it is never reported as an absent match.
/// Empty regex matches are allowed. To repeat forward, advance an empty match by one byte;
/// backward can resume at the previous match's lower bound.
public enum ViewerSearch {
    public static let maximumRegexLineBytes = 1_048_576

    public static func validate(_ query: ViewerSearchQuery) throws {
        _ = try ViewerSearchPlan(query)
    }

    public static func find(document: ViewerDocument, query: ViewerSearchQuery, from: Int64,
                            direction: ViewerSearchDirection = .forward,
                            cancellation: ViewerCancellation? = nil,
                            onProgress: ((Int64) -> Void)? = nil) throws -> ViewerSearchResult? {
        let worker = ViewerSearchWorker(document: document, plan: try ViewerSearchPlan(query),
                                        from: max(0, min(from, document.size)), direction: direction,
                                        cancellation: cancellation, onProgress: onProgress)
        try worker.checkCancellation()
        try document.source.verifyUnchanged()
        let firstSearchableByte = query.mode == .hex ? 0 : Int64(document.bomLength)
        if direction == .backward, worker.from <= firstSearchableByte { return nil }
        let result: ViewerSearchResult?
        switch query.mode {
        case .literal: result = try worker.literal()
        case .regex: result = try worker.regex()
        case .hex: result = try worker.hex()
        }
        try worker.checkCancellation()
        try document.source.verifyUnchanged()
        return result
    }
}

private struct ViewerSearchPlan {
    let query: ViewerSearchQuery
    let expression: NSRegularExpression?
    let bytes: [UInt8]

    init(_ query: ViewerSearchQuery) throws {
        guard !query.pattern.isEmpty else { throw ViewerSearchError.emptyQuery }
        guard query.pattern.utf16.count <= 4_096 else { throw ViewerSearchError.queryTooLong }
        self.query = query
        if query.mode == .regex {
            guard !Self.requiresMultipleLines(query.pattern) else { throw ViewerSearchError.unsupportedMultilineRegex }
            do {
                expression = try NSRegularExpression(pattern: query.pattern,
                    options: query.caseSensitive ? [] : [.caseInsensitive])
            } catch { throw ViewerSearchError.invalidRegularExpression(error.localizedDescription) }
        } else { expression = nil }
        if query.mode == .hex {
            let digits = query.pattern.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            guard !digits.isEmpty, digits.count.isMultiple(of: 2),
                  digits.allSatisfy({ $0.isASCII && CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) })
            else { throw ViewerSearchError.invalidHex }
            let characters = Array(digits)
            var parsed = [UInt8]()
            for index in stride(from: 0, to: characters.count, by: 2) {
                let pair = String(String.UnicodeScalarView(characters[index...index + 1]))
                guard let byte = UInt8(pair, radix: 16) else { throw ViewerSearchError.invalidHex }
                parsed.append(byte)
            }
            bytes = parsed
        } else { bytes = [] }
    }

    private static func requiresMultipleLines(_ pattern: String) -> Bool {
        if pattern.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) { return true }
        // Explicit line separators, file anchors and multiline/dot-all flags have semantics
        // that cannot be preserved by evaluating each logical line independently.
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

private struct ViewerSearchBuffer {
    var units = [UInt16]()
    // One source offset per UTF-16 boundary, including the end boundary.
    var offsets = [Int64]()

    mutating func append(_ page: ViewerPage) {
        let incoming = Array(page.text.utf16)
        if !offsets.isEmpty { offsets.removeLast() }
        units.append(contentsOf: incoming)
        offsets.append(contentsOf: (0...incoming.count).map { page.byteOffset(forUTF16: $0) })
    }

    mutating func retainSuffix(_ count: Int) {
        var start = max(0, units.count - count)
        if start > 0, start < units.count, (0xDC00...0xDFFF).contains(units[start]) { start -= 1 }
        units = Array(units[start...]); offsets = Array(offsets[start...])
    }

    func byteRange(_ range: NSRange) -> Range<Int64> {
        var end = range.location + range.length
        // Regex can explicitly address one surrogate. Highlight its complete source scalar.
        if range.length > 0, end < units.count, (0xDC00...0xDFFF).contains(units[end]) { end += 1 }
        return offsets[range.location]..<offsets[end]
    }
}

private final class ViewerSearchWorker {
    let document: ViewerDocument
    let plan: ViewerSearchPlan
    let from: Int64
    let direction: ViewerSearchDirection
    let cancellation: ViewerCancellation?
    let onProgress: ((Int64) -> Void)?
    let blockSize = 65_536

    init(document: ViewerDocument, plan: ViewerSearchPlan, from: Int64, direction: ViewerSearchDirection,
         cancellation: ViewerCancellation?, onProgress: ((Int64) -> Void)?) {
        self.document = document; self.plan = plan; self.from = from; self.direction = direction
        self.cancellation = cancellation; self.onProgress = onProgress
    }

    func checkCancellation() throws {
        if cancellation?.isCancelled == true { throw ViewerSearchError.cancelled }
    }

    func eligible(_ range: Range<Int64>) -> Bool {
        direction == .forward ? range.lowerBound >= from : range.lowerBound < from
    }

    func literal() throws -> ViewerSearchResult? {
        var cursor = direction == .forward ? max(from, Int64(document.bomLength)) : Int64(document.bomLength)
        var buffer = ViewerSearchBuffer()
        var latest: ViewerSearchResult?
        // Unicode case folding can expand a scalar to several UTF-16 units.
        let overlap = plan.query.pattern.utf16.count * 4 + 4
        while cursor < document.size {
            try checkCancellation()
            let page = try document.page(at: cursor, byteCount: blockSize)
            guard page.endOffset > cursor else { throw ViewerError.changedFile }
            buffer.append(page)
            let text = String(decoding: buffer.units, as: UTF16.self) as NSString
            var options: NSString.CompareOptions = [.literal]
            if !plan.query.caseSensitive { options.insert(.caseInsensitive) }
            if direction == .backward { options.insert(.backwards) }
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let match = text.range(of: plan.query.pattern, options: options, range: searchRange)
                if match.location == NSNotFound { break }
                let range = buffer.byteRange(match)
                if eligible(range) {
                    let result = ViewerSearchResult(byteRange: range)
                    if direction == .forward { return result }
                    if latest == nil || range.lowerBound > latest!.byteRange.lowerBound { latest = result }
                    break
                }
                if direction == .forward {
                    var next = match.location + 1
                    if next < buffer.units.count, (0xDC00...0xDFFF).contains(buffer.units[next]) { next += 1 }
                    searchRange = NSRange(location: next, length: text.length - next)
                } else {
                    // Exclude this match's end, keeping earlier starts whose matches
                    // overlap it. Truncating at its start would hide those matches.
                    searchRange.length = match.location + match.length - 1
                }
            }
            cursor = page.endOffset
            onProgress?(cursor)
            let limit = from + min(document.size - from, Int64(overlap * 4))
            if direction == .backward, cursor >= limit { break }
            buffer.retainSuffix(overlap)
        }
        return latest
    }

    func regex() throws -> ViewerSearchResult? {
        guard let expression = plan.expression else { return nil }
        var cursor = Int64(document.bomLength)
        var line = ViewerSearchBuffer(units: [], offsets: [cursor])
        var lineEnd = cursor
        var lineTooLong = false
        var previousWasCR = false
        var latest: ViewerSearchResult?

        func inspectLine() throws -> ViewerSearchResult? {
            try checkCancellation()
            if direction == .forward, lineEnd < from { return nil }
            if lineTooLong { throw ViewerSearchError.regexLineTooLong(offset: line.offsets[0]) }
            let text = String(decoding: line.units, as: UTF16.self)
            let deadline = ProcessInfo.processInfo.systemUptime + 0.05
            var found: ViewerSearchResult?
            var timedOut = false
            var failed = false
            // Start forward matching at the requested position, preserving line anchors and
            // lookbehind context. Filtering an enumeration from zero would miss overlaps.
            var beginning = direction == .forward
                ? (line.offsets.firstIndex(where: { $0 >= from }) ?? line.units.count) : 0
            repeat {
                var lastStart: Int?
                expression.enumerateMatches(in: text,
                                            options: [.reportProgress, .reportCompletion, .withoutAnchoringBounds, .withTransparentBounds],
                                            range: NSRange(location: beginning, length: line.units.count - beginning)) { match, flags, stop in
                    if self.cancellation?.isCancelled == true { stop.pointee = true }
                    else if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; stop.pointee = true }
                    else if flags.contains(.internalError) { failed = true; stop.pointee = true }
                    else if let match {
                        let range = line.byteRange(match.range)
                        if self.eligible(range) {
                            found = ViewerSearchResult(byteRange: range)
                            lastStart = match.range.location
                            if self.direction == .forward { stop.pointee = true }
                        } else if self.direction == .backward, range.lowerBound >= self.from {
                            stop.pointee = true
                        }
                    }
                }
                try checkCancellation()
                if timedOut || ProcessInfo.processInfo.systemUptime >= deadline { throw ViewerSearchError.regexDeadlineExceeded }
                if failed { throw ViewerSearchError.regexExecutionFailed }
                guard direction == .backward, let lastStart, lastStart < line.units.count else { break }
                // Recheck the last match's suffix to include overlapping matches. Most
                // patterns finish in one additional pass; all passes share one deadline.
                beginning = lastStart + 1
                if beginning < line.units.count, (0xDC00...0xDFFF).contains(line.units[beginning]) { beginning += 1 }
            } while beginning <= line.units.count
            return found
        }

        while cursor < document.size {
            try checkCancellation()
            let page = try document.page(at: cursor, byteCount: blockSize)
            guard page.endOffset > cursor else { throw ViewerError.changedFile }
            let units = Array(page.text.utf16)
            for (index, unit) in units.enumerated() {
                if index & 4_095 == 0 { try checkCancellation() }
                let start = page.byteOffset(forUTF16: index)
                let end = page.byteOffset(forUTF16: index + 1)
                if previousWasCR && unit == 0x0A {
                    line.offsets = [end]; lineEnd = end; previousWasCR = false; continue
                }
                previousWasCR = false
                if [UInt16(0x0A), 0x0D, 0x85, 0x2028, 0x2029].contains(unit) {
                    if let found = try inspectLine() {
                        if direction == .forward { return found }
                        latest = found
                    }
                    if direction == .backward, start >= from { return latest }
                    line = ViewerSearchBuffer(units: [], offsets: [end])
                    lineEnd = end; lineTooLong = false
                    previousWasCR = unit == 0x0D
                } else {
                    lineEnd = end
                    if end - line.offsets[0] > Int64(ViewerSearch.maximumRegexLineBytes) {
                        lineTooLong = true
                        // Earlier lines cannot contain a forward result. Discard their
                        // excess bytes and defer failure until this line reaches `from`.
                        if direction == .backward || end >= from {
                            throw ViewerSearchError.regexLineTooLong(offset: line.offsets[0])
                        }
                    } else {
                        line.units.append(unit); line.offsets.append(end)
                    }
                }
            }
            cursor = page.endOffset; onProgress?(cursor)
        }
        if let found = try inspectLine() {
            if direction == .forward { return found }
            latest = found
        }
        return latest
    }

    func hex() throws -> ViewerSearchResult? {
        let needle = plan.bytes
        // KMP retains only the query and its prefix table, including across read boundaries.
        var prefixes = [Int](repeating: 0, count: needle.count)
        if needle.count > 1 {
            for index in 1..<needle.count {
                var length = prefixes[index - 1]
                while length > 0, needle[index] != needle[length] { length = prefixes[length - 1] }
                if needle[index] == needle[length] { length += 1 }
                prefixes[index] = length
            }
        }
        var cursor: Int64 = direction == .forward ? from : 0
        var length = 0
        var latest: ViewerSearchResult?
        while cursor < document.size {
            try checkCancellation()
            try document.source.verifyUnchanged()
            let bytes = try document.source.read(offset: cursor, count: min(blockSize, Int(document.size - cursor)))
            guard !bytes.isEmpty else { throw ViewerError.changedFile }
            for (index, byte) in bytes.enumerated() {
                if index & 4_095 == 0 { try checkCancellation() }
                while length > 0, byte != needle[length] { length = prefixes[length - 1] }
                if byte == needle[length] { length += 1 }
                if length == needle.count {
                    let end = cursor + Int64(index) + 1
                    let range = (end - Int64(needle.count))..<end
                    if eligible(range) {
                        let found = ViewerSearchResult(byteRange: range)
                        if direction == .forward { return found }
                        latest = found
                    }
                    length = prefixes[length - 1]
                }
            }
            cursor += Int64(bytes.count); onProgress?(cursor)
            if direction == .backward, cursor >= from + min(document.size - from, Int64(needle.count)) { break }
        }
        return latest
    }
}
