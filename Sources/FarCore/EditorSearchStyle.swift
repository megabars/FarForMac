import Foundation

// Preserve-style behavior adapted from FarGroup/FarManager preservestyle.cpp,
// commit 1a6b02544b339615232078e0551463ef15b73ff9.
// Copyright © 2013 Far Group. BSD 3-clause terms: THIRD_PARTY_NOTICES.md.
// Swift uses Unicode scalars and Foundation casing in place of Windows wchar_t APIs.
private final class EditorStyleSearchBudget {
    private let deadline = ProcessInfo.processInfo.systemUptime + 0.25
    private var work = 0
    func consume(_ units: Int) throws {
        work += units
        guard work <= 16 * 1_048_576, ProcessInfo.processInfo.systemUptime < deadline else { throw EditorEditingError.styleSearchLimit }
    }
}

struct EditorSearchStyle {
    struct Token {
        var text: String
        var separator: String
        var mask: Int { EditorSearchStyle.styleMask(text) }
    }
    let pattern: [Token]
    let caseSensitive: Bool
    private let budget = EditorStyleSearchBudget()

    init(pattern: String, caseSensitive: Bool) {
        self.pattern = Self.tokens(pattern); self.caseSensitive = caseSensitive
    }

    /// A literal token pattern can discover different identifier separators/camel case.
    /// The caller checks whole-word boundaries against the original document.
    func firstRange(in text: String, from: Int, backwards: Bool = false, wholeWords: Bool = false) throws -> NSRange? {
        let source = text as NSString
        guard let first = pattern.first else { return nil }
        let options: NSString.CompareOptions = caseSensitive ? [.literal] : [.literal, .caseInsensitive]
        var cursor = backwards ? 0 : from
        var latest: NSRange?
        let comparisonCost = max(1, pattern.reduce(0) { $0 + $1.text.utf16.count })
        while cursor < source.length {
            let start = source.range(of: first.text, options: options, range: NSRange(location: cursor, length: source.length - cursor))
            guard start.location != NSNotFound, !backwards || start.location < from else { break }
            try budget.consume(comparisonCost)
            var end = NSMaxRange(start), matched = !Self.internalBoundary(source, range: start)
            for token in pattern.dropFirst() {
                // Explicit separators must be single and surrounded by nonseparators.
                if end < source.length, Self.separator(source.character(at: end)),
                   end > 0, !Self.separator(source.character(at: end - 1)),
                   end + 1 < source.length, !Self.separator(source.character(at: end + 1)) {
                    end += 1
                } else {
                    guard end > 0, end < source.length,
                          Self.lower(source.character(at: end - 1)), Self.upper(source.character(at: end)) else { matched = false; break }
                }
                let next = source.range(of: token.text, options: options.union(.anchored), range: NSRange(location: end, length: source.length - end))
                guard next.location != NSNotFound, !Self.internalBoundary(source, range: next) else { matched = false; break }
                end = NSMaxRange(next)
            }
            if matched {
                let range = NSRange(location: start.location, length: end - start.location)
                let foundTokens = Self.tokens(source.substring(with: range))
                if foundTokens.map({ $0.text.utf16.count }) == pattern.map({ $0.text.utf16.count }),
                   !wholeWords || SearchWordBoundary.isWholeWord(text, range: range) {
                    if !backwards { return range }
                    latest = range
                }
            }
            cursor = start.location + ((0xD800...0xDBFF).contains(source.character(at: start.location)) ? 2 : 1)
        }
        if let latest { return latest }
        // FAR falls back to ordinary literal search after a full unsuccessful style scan.
        cursor = backwards ? 0 : from
        while cursor < source.length {
            let range = source.range(of: pattern.map { $0.separator + $0.text }.joined(), options: options,
                                     range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound, !backwards || range.location < from else { break }
            if !wholeWords || SearchWordBoundary.isWholeWord(text, range: range) {
                if !backwards { return range }; latest = range
            }
            cursor = range.location + ((0xD800...0xDBFF).contains(source.character(at: range.location)) ? 2 : 1)
        }
        return latest
    }

    private static func internalBoundary(_ source: NSString, range: NSRange) -> Bool {
        guard range.length > 1 else { return false }
        for offset in (range.location + 1)..<NSMaxRange(range) {
            if lower(source.character(at: offset - 1)), upper(source.character(at: offset)) { return true }
            if separator(source.character(at: offset)), !separator(source.character(at: offset - 1)),
               offset + 1 < source.length, !separator(source.character(at: offset + 1)) { return true }
        }
        return false
    }

    func replacement(_ replacement: String, in source: String, range: NSRange) throws -> String {
        try budget.consume(replacement.utf16.count)
        guard !replacement.isEmpty else { return replacement }
        let original = (source as NSString).substring(with: range)
        let sourceTokens = Self.tokens(original)
        // A fallback literal match preserves just the first letter, as strmix.cpp does.
        let isStyleMatch = sourceTokens.count == pattern.count && zip(sourceTokens, pattern).allSatisfy {
            $0.text.utf16.count == $1.text.utf16.count && $0.text.compare($1.text, options: caseSensitive ? [.literal] : [.literal, .caseInsensitive]) == .orderedSame
        } && sourceTokens.allSatisfy { !Self.internalBoundary($0.text as NSString, range: NSRange(location: 0, length: $0.text.utf16.count)) }
        if !isStyleMatch {
            guard let first = replacement.unicodeScalars.first, first.properties.isAlphabetic,
                  let originalFirst = original.unicodeScalars.first, originalFirst.properties.isAlphabetic else { return replacement }
            let tail = String(String.UnicodeScalarView(replacement.unicodeScalars.dropFirst()))
            if originalFirst.properties.isUppercase { return String(first).uppercased() + tail }
            if originalFirst.properties.isLowercase { return String(first).lowercased() + tail }
            return replacement
        }
        var result = Self.tokens(replacement)
        try budget.consume(0)
        guard !sourceTokens.isEmpty, !result.isEmpty else { return replacement }
        if result.count == sourceTokens.count {
            let common = sourceTokens.reduce(7) { $0 & $1.mask }
            for index in result.indices {
                result[index].text = Self.apply(result[index].text, mask: common != 0 ? common : sourceTokens[index].mask)
                result[index].separator = sourceTokens[index].separator
            }
        } else {
            result[0].text = Self.apply(result[0].text, mask: sourceTokens[0].mask)
            result[0].separator = sourceTokens[0].separator
            var mask: Int?, separator = sourceTokens.last!.separator
            if sourceTokens.count > 1 { mask = sourceTokens.dropFirst().reduce(7) { $0 & $1.mask } }
            if mask == nil, let context = try Self.expansion(source, range: range, budget: budget) { mask = context.mask; separator = context.separator }
            if mask == nil { mask = sourceTokens[0].mask; separator = result.last!.separator }
            for index in result.indices.dropFirst() {
                result[index].text = Self.apply(result[index].text, mask: mask!)
                result[index].separator = separator
            }
        }
        return result.map { $0.separator + $0.text }.joined()
    }

    private static func expansion(_ source: String, range: NSRange, budget: EditorStyleSearchBudget) throws -> Token? {
        let value = source as NSString, end = NSMaxRange(range)
        if end < value.length, alphanumeric(value.character(at: end)) || separator(value.character(at: end)) {
            var right = end + 1
            while right < value.length {
                if (right - end) % 1024 == 0 { try budget.consume(1024) }
                if !alphanumeric(value.character(at: right)) || lower(value.character(at: right - 1)) && upper(value.character(at: right)) { break }
                right += 1
            }
            try budget.consume(right - end < 1024 ? right - end : (right - end) % 1024)
            let expanded = tokens(value.substring(with: NSRange(location: range.location, length: right - range.location)))
            if expanded.count > 1 { return expanded.last }
        }
        if range.location >= 2, alphanumeric(value.character(at: range.location - 1)) || separator(value.character(at: range.location - 1)) {
            var left = range.location - 2
            while left >= 0 {
                if (range.location - left) % 1024 == 0 { try budget.consume(1024) }
                if !alphanumeric(value.character(at: left)) || lower(value.character(at: left)) && upper(value.character(at: left + 1)) { break }
                left -= 1
            }
            left += 1
            try budget.consume(range.location - left < 1024 ? range.location - left : (range.location - left) % 1024)
            let expanded = tokens(value.substring(with: NSRange(location: left, length: end - left)))
            if expanded.count > 1 { return expanded.last }
        }
        return nil
    }

    static func tokens(_ text: String) -> [Token] {
        let chars = Array(text.unicodeScalars)
        guard !chars.isEmpty else { return [] }
        var separators = Set<Int>()
        var index = 0
        while index + 2 < chars.count {
            if !separator(chars[index].value), separator(chars[index + 1].value), !separator(chars[index + 2].value) {
                separators.insert(index + 1); index += 1
            }
            index += 1
        }
        var result = [Token](), beginning = 0
        func append(until end: Int) {
            let prefix = beginning > 0 && separators.contains(beginning - 1) ? String(chars[beginning - 1]) : ""
            result.append(Token(text: String(String.UnicodeScalarView(chars[beginning..<end])), separator: prefix))
        }
        index = 0
        // FAR deliberately examines boundaries with one following character available.
        while index + 2 < chars.count {
            if separators.contains(index + 1) {
                append(until: index + 1); beginning = index + 2; index += 1
            } else if !separators.contains(index), chars[index].properties.isLowercase, chars[index + 1].properties.isUppercase {
                append(until: index + 1); beginning = index + 1
            }
            index += 1
        }
        if beginning < chars.count { append(until: chars.count) }
        if result.count > 2, result.dropFirst(2).contains(where: { $0.separator != result[1].separator }) {
            return [Token(text: text, separator: "")]
        }
        return result
    }

    private static func styleMask(_ text: String) -> Int {
        let chars = Array(text.unicodeScalars)
        var mask = 7
        for (index, scalar) in chars.enumerated() {
            if !scalar.properties.isUppercase { mask &= ~1; if index == 0 { mask &= ~4 } }
            if !scalar.properties.isLowercase { mask &= ~2; if index > 0 { mask &= ~4 } }
        }
        return mask
    }
    private static func apply(_ text: String, mask: Int) -> String {
        if mask & 4 != 0 {
            let chars = text.unicodeScalars
            guard let first = chars.first else { return text }
            return String(first).uppercased() + String(String.UnicodeScalarView(chars.dropFirst())).lowercased()
        }
        if mask & 2 != 0 { return text.lowercased() }
        if mask & 1 != 0 { return text.uppercased() }
        return text
    }
    private static func separator<T: BinaryInteger>(_ value: T) -> Bool { value == 95 || value == 45 || value == 46 }
    private static func lower(_ value: UInt16) -> Bool { UnicodeScalar(value)?.properties.isLowercase == true }
    private static func upper(_ value: UInt16) -> Bool { UnicodeScalar(value)?.properties.isUppercase == true }
    private static func alphanumeric(_ value: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(value) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
