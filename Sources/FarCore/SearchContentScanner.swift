import Foundation

struct SearchContentMatch {
    let snippet: String
    let line: Int?
    let byteOffset: Int64?
}

/// Strict decoding for search, unlike the viewer's replacement-character display.
/// Literal searches retain at most one decoded page plus a bounded match overlap.
enum SearchContentScanner {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private struct PrefixSource: ViewerByteSource {
        let source: any ViewerByteSource
        let size: Int64
        var identity: String { source.identity }
        func verifyUnchanged() throws { try source.verifyUnchanged() }
        func read(offset: Int64, count: Int) throws -> Data {
            guard offset >= 0, offset <= size, count >= 0 else { throw ViewerError.invalidRange }
            return try source.read(offset: offset, count: Int(min(Int64(count), size - offset)))
        }
    }

    static func prefix(_ source: any ViewerByteSource, firstBytes: Int?) -> any ViewerByteSource {
        guard let firstBytes, Int64(firstBytes) < source.size else { return source }
        return PrefixSource(source: source, size: Int64(firstBytes))
    }

    static func document(_ source: any ViewerByteSource, encoding: ViewerEncoding,
                         firstBytes: Int?) throws -> ViewerDocument {
        let bounded = prefix(source, firstBytes: firstBytes)
        let document = try ViewerDocument(source: bounded, encoding: encoding)
        guard bounded.size < source.size else { return document }
        // A byte boundary can truncate one Unicode scalar. Discard just that
        // tail, while still reporting invalid sequences earlier in the prefix.
        let count = Int(min(4, bounded.size))
        let tail = Array(try bounded.read(offset: bounded.size - Int64(count), count: count))
        let candidateEncoding = encoding == .automatic && document.encoding == .windows1252 ? .utf8 : document.encoding
        let incomplete: Int
        switch candidateEncoding {
        case .utf8: incomplete = incompleteUTF8Suffix(tail)
        case .utf16LE, .utf16BE:
            let odd = Int(bounded.size % 2)
            let end = tail.count - odd
            if end >= 2 {
                let highByte = tail[candidateEncoding == .utf16LE ? end - 1 : end - 2]
                incomplete = odd + ((0xD8...0xDB).contains(highByte) ? 2 : 0)
            } else { incomplete = odd }
        default: incomplete = 0
        }
        guard incomplete > 0 else { return document }
        return try ViewerDocument(source: PrefixSource(source: source, size: bounded.size - Int64(incomplete)), encoding: encoding)
    }

    private static func incompleteUTF8Suffix(_ bytes: [UInt8]) -> Int {
        guard let start = bytes.lastIndex(where: { !(0x80...0xBF).contains($0) }) else { return 0 }
        let lead = bytes[start], count = bytes.count - start
        let width: Int
        switch lead {
        case 0xC2...0xDF: width = 2
        case 0xE0...0xEF: width = 3
        case 0xF0...0xF4: width = 4
        default: return 0
        }
        guard count < width else { return 0 }
        if count > 1 {
            let second = bytes[start + 1]
            if (lead == 0xE0 && second < 0xA0) || (lead == 0xED && second >= 0xA0) ||
                (lead == 0xF0 && second < 0x90) || (lead == 0xF4 && second >= 0x90) { return 0 }
        }
        return count
    }
    /// FAR's masked field is HH HH ... HH. Free-form input accepts whitespace
    /// between complete pairs; compact runs of pairs also work. No odd-nibble correction or wildcard bytes.
    static func hexBytes(_ text: String) throws -> [UInt8] {
        guard !text.isEmpty, text.utf16.count <= 4_096 else {
            throw Failure("Укажите HEX-запрос длиной от 1 до 4096 символов: пары 00…FF через пробел.")
        }
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { throw Failure("HEX-запрос должен содержать хотя бы один байт 00…FF.") }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 65 + 10
            case 97...102: return byte - 97 + 10
            default: return nil
            }
        }
        return try tokens.flatMap { token -> [UInt8] in
            let digits = Array(token.utf8)
            guard digits.count.isMultiple(of: 2), digits.allSatisfy({ nibble($0) != nil }) else {
                throw Failure("Некорректный HEX-запрос: нужны пары 00…FF через пробел; 0x, нечётные цифры и шаблоны не поддерживаются.")
            }
            return stride(from: 0, to: digits.count, by: 2).map { nibble(digits[$0])! << 4 | nibble(digits[$0 + 1])! }
        }
    }

    /// KMP keeps only a 64 KiB page, the bounded query and its prefix table.
    /// Scanning continues after the first match to detect read/snapshot failures.
    static func scanBytes(source: any ViewerByteSource, query: [UInt8],
                          cancellation: SearchCancellation) throws -> SearchContentMatch? {
        guard !query.isEmpty, query.count <= 2_048 else { throw ViewerError.invalidRange }
        var prefix = [Int](repeating: 0, count: query.count)
        var matched = 0
        for index in 1..<query.count {
            while matched > 0 && query[index] != query[matched] { matched = prefix[matched - 1] }
            if query[index] == query[matched] { matched += 1 }
            prefix[index] = matched
        }
        matched = 0
        var offset: Int64 = 0, first: Int64?
        try source.verifyUnchanged()
        while offset < source.size {
            if cancellation.isCancelled { throw ViewerError.cancelled }
            try autoreleasepool {
                let count = Int(min(65_536, source.size - offset))
                let page = try source.read(offset: offset, count: count)
                guard page.count == count else { throw ViewerError.changedFile }
                if first == nil {
                    for (index, byte) in page.enumerated() {
                        while matched > 0 && byte != query[matched] { matched = prefix[matched - 1] }
                        if byte == query[matched] { matched += 1 }
                        if matched == query.count {
                            first = offset + Int64(index + 1 - query.count)
                            break
                        }
                    }
                }
                offset += Int64(page.count)
            }
        }
        if cancellation.isCancelled { throw ViewerError.cancelled }
        try source.verifyUnchanged()
        guard let first else { return nil }
        // The preview starts exactly at the match, including BOM and binary zeroes.
        let preview = try source.read(offset: first, count: min(32, query.count))
        guard preview.count == min(32, query.count) else { throw ViewerError.changedFile }
        try source.verifyUnchanged()
        if cancellation.isCancelled { throw ViewerError.cancelled }
        let hex = preview.map { String(format: "%02X", $0) }.joined(separator: " ")
        let suffix = query.count > preview.count ? " …" : ""
        return SearchContentMatch(snippet: "0x" + String(first, radix: 16, uppercase: true) + ": " + hex + suffix,
                                  line: nil, byteOffset: first)
    }
    static func scan(document: ViewerDocument, expression: NSRegularExpression,
                     literal: Bool, queryLength: Int, cancellation: SearchCancellation) throws -> SearchContentMatch? {
        var offset = Int64(document.bomLength), text = "", first: SearchContentMatch?
        var baseLine = 1, previousCR = false
        // ICU literal case folding can expand scalars. Keep ample overlap for
        // the bounded query and surrounding snippet, never a whole long line.
        let overlap = max(256, queryLength * 4 + 160)
        while offset < document.size {
            if cancellation.isCancelled { throw ViewerError.cancelled }
            try autoreleasepool {
                let page = try document.page(at: offset)
                guard !page.invalidSequences, !page.text.unicodeScalars.contains(where: { $0.value == 0 }) else {
                    throw Failure("Содержимое пропущено: неверная кодировка или двоичные нули в тексте.")
                }
                guard page.endOffset > offset else { throw ViewerError.invalidRange }
                offset = page.endOffset
                if !literal || first == nil {
                    text += page.text
                    if literal {
                        if let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                            first = describe(text, range: match.range, baseLine: baseLine, previousCR: previousCR)
                            text = ""
                        } else {
                            let ns = text as NSString
                            var drop = max(0, ns.length - overlap)
                            if drop > 0 && drop < ns.length && (0xDC00...0xDFFF).contains(ns.character(at: drop)) { drop -= 1 }
                            countLines(ns.substring(to: drop), line: &baseLine, previousCR: &previousCR)
                            text = ns.substring(from: drop)
                        }
                    }
                }
            }
        }
        if cancellation.isCancelled { throw ViewerError.cancelled }
        try document.source.verifyUnchanged()
        if literal { return first }
        let budget = MatchingTimeBudget(seconds: 0.05)
        var match: NSRange?, timedOut = false, failed = false
        expression.enumerateMatches(in: text, options: [.reportProgress, .reportCompletion],
                                    range: NSRange(location: 0, length: (text as NSString).length)) { result, flags, stop in
            if cancellation.isCancelled { stop.pointee = true }
            else if budget.expired { timedOut = true; stop.pointee = true }
            else if flags.contains(.internalError) { failed = true; stop.pointee = true }
            else if let result { match = result.range; stop.pointee = true }
        }
        if cancellation.isCancelled { throw ViewerError.cancelled }
        if timedOut || budget.expired {
            throw Failure("Содержимое пропущено: превышено процессорное время проверки выражения (50 мс).")
        }
        if failed { throw Failure("Содержимое пропущено: ошибка выполнения регулярного выражения.") }
        return match.map { describe(text, range: $0, baseLine: 1, previousCR: false) }
    }
    private static func describe(_ text: String, range: NSRange, baseLine: Int, previousCR: Bool) -> SearchContentMatch {
        let ns = text as NSString
        var start = max(0, range.location - 80)
        var end = min(ns.length, max(range.location + min(range.length, 160), range.location + 80))
        if start > 0 && (0xDC00...0xDFFF).contains(ns.character(at: start)) { start -= 1 }
        if end < ns.length && end > 0 && (0xD800...0xDBFF).contains(ns.character(at: end - 1)) { end += 1 }
        var line = baseLine, cr = previousCR
        countLines(ns.substring(to: range.location), line: &line, previousCR: &cr)
        let snippet = ns.substring(with: NSRange(location: start, length: end - start)).components(separatedBy: .newlines).joined(separator: " ")
        return SearchContentMatch(snippet: snippet, line: line, byteOffset: nil)
    }
    private static func countLines(_ text: String, line: inout Int, previousCR: inout Bool) {
        for unit in text.utf16 {
            switch unit {
            case 13, 0x85, 0x2028, 0x2029: line += 1
            case 10: if !previousCR { line += 1 }
            default: break
            }
            previousCR = unit == 13
        }
    }
}
