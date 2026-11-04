import Foundation

public enum SearchTextFoldingError: Error, LocalizedError, Equatable {
    case expansionTooLarge(limit: Int)
    public var errorDescription: String? {
        switch self {
        case .expansionTooLarge(let limit): return "Нестрогий поиск неполон: преобразованный текст превышает предел \(limit) единиц UTF-16."
        }
    }
}

/// Unicode adaptation of FAR's fuzzy_searcher_impl (Far Group © 2017).
/// See THIRD_PARTY_NOTICES.md and docs/VIEWER_REFERENCE.md for the source and differences.
/// Compatibility / ligature / decimal-digit folding and removal of nonalphabetic
/// marks are independent of case sensitivity. Every match maps back to complete
/// original scalars, including trailing discarded marks, for safe replacement.
public struct SearchTextFolding: @unchecked Sendable {
    public static let maximumFoldedUTF16 = 16 * 1_024 * 1_024
    // Immutable NSString is prepared once; repeated editor matches never bridge
    // and copy the complete haystack again. It is never exposed for mutation.
    private let folded: NSString
    private let starts: [UInt32]
    private let ends: [UInt32]
    private let originalLength: Int
    private let caseSensitive: Bool

    public init(_ text: String, caseSensitive: Bool = false,
                maximumFoldedUTF16: Int = Self.maximumFoldedUTF16) throws {
        self.caseSensitive = caseSensitive
        var output = String(), starts = [UInt32](), ends = [UInt32]()
        let capacity = max(0, min(text.utf16.count, maximumFoldedUTF16))
        starts.reserveCapacity(capacity); ends.reserveCapacity(capacity)
        var cache = [Unicode.Scalar: String]()
        var offset = 0, previousStart = 0
        for scalar in text.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if scalar.value < 128 {
                guard starts.count < maximumFoldedUTF16 else { throw SearchTextFoldingError.expansionTooLarge(limit: maximumFoldedUTF16) }
                previousStart = starts.count
                let value = !caseSensitive && (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
                output.unicodeScalars.append(value)
                starts.append(UInt32(offset)); ends.append(UInt32(offset + 1)); offset += 1
                continue
            }
            let part: String
            if let cached = cache[scalar] { part = cached }
            else { part = Self.foldScalar(scalar, caseSensitive: caseSensitive); cache[scalar] = part }
            if part.isEmpty {
                // Include discarded decomposed accents in the preceding source
                // scalar's highlight, without swallowing leading marks.
                if !ends.isEmpty {
                    for index in previousStart..<ends.count { ends[index] = UInt32(offset + width) }
                }
            } else {
                previousStart = starts.count
                let count = part.utf16.count
                guard count <= maximumFoldedUTF16 - starts.count else { throw SearchTextFoldingError.expansionTooLarge(limit: maximumFoldedUTF16) }
                output.append(part)
                starts.append(contentsOf: repeatElement(UInt32(offset), count: count))
                ends.append(contentsOf: repeatElement(UInt32(offset + width), count: count))
            }
            offset += width
        }
        folded = output as NSString; self.starts = starts; self.ends = ends; originalLength = offset
    }

    public static func fold(_ text: String, caseSensitive: Bool = false) -> String {
        var output = String()
        var cache = [Unicode.Scalar: String]()
        for scalar in text.unicodeScalars {
            if scalar.value < 128 {
                output.unicodeScalars.append(!caseSensitive && (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar)
            } else if let part = cache[scalar] { output.append(part) }
            else { let part = foldScalar(scalar, caseSensitive: caseSensitive); cache[scalar] = part; output.append(part) }
        }
        return output
    }

    public func firstRange(of pattern: String, in range: NSRange? = nil, backwards: Bool = false) -> NSRange? {
        firstRange(ofFolded: Self.fold(pattern, caseSensitive: caseSensitive), in: range, backwards: backwards)
    }

    /// `pattern` must already have been folded with the same case option.
    /// Search bounds and the returned range are in the original text's UTF-16.
    public func firstRange(ofFolded pattern: String, in range: NSRange? = nil, backwards: Bool = false) -> NSRange? {
        guard !pattern.isEmpty else { return nil }
        let range = range ?? NSRange(location: 0, length: originalLength)
        guard range.location >= 0, range.length >= 0, range.location <= originalLength,
              range.length <= originalLength - range.location else { return nil }
        let first = lowerBound(starts, range.location)
        let last = upperBound(ends, NSMaxRange(range))
        guard first < last else { return nil }
        let match = folded.range(of: pattern, options: backwards ? [.literal, .backwards] : [.literal],
                                               range: NSRange(location: first, length: last - first))
        guard match.location != NSNotFound else { return nil }
        let start = starts[match.location], end = ends[NSMaxRange(match) - 1]
        return NSRange(location: Int(start), length: Int(end - start))
    }

    /// Original UTF-16 boundary for a streaming suffix. Keeps all source marks
    /// contributing to the retained folded suffix, plus one preceding scalar.
    public func suffixStart(keepingFoldedUnits count: Int) -> Int {
        guard !starts.isEmpty else { return 0 }
        let index = max(0, starts.count - max(1, count))
        let boundary = starts[index]
        guard boundary > 0 else { return 0 }
        let previous = lowerBound(starts, Int(boundary)) - 1
        return previous >= 0 ? Int(starts[previous]) : 0
    }

    private func lowerBound(_ values: [UInt32], _ target: Int) -> Int {
        var low = 0, high = values.count
        while low < high { let middle = (low + high) / 2; if Int(values[middle]) < target { low = middle + 1 } else { high = middle } }
        return low
    }

    private func upperBound(_ values: [UInt32], _ target: Int) -> Int {
        var low = 0, high = values.count
        while low < high { let middle = (low + high) / 2; if Int(values[middle]) <= target { low = middle + 1 } else { high = middle } }
        return low
    }

    private static func foldScalar(_ scalar: Unicode.Scalar, caseSensitive: Bool) -> String {
        // ASCII is the common case in bounded viewer pages and large editors.
        if scalar.value < 128 {
            if !caseSensitive, (65...90).contains(scalar.value) { return String(Unicode.Scalar(scalar.value + 32)!) }
            return String(scalar)
        }
        let expanded: String
        switch scalar.value {
        case 0x00C6: expanded = "AE"
        case 0x00E6: expanded = "ae"
        case 0x0152: expanded = "OE"
        case 0x0153: expanded = "oe"
        case 0x00DF: expanded = "ss"
        case 0x1E9E: expanded = "SS"
        default: expanded = String(scalar)
        }
        var result = String()
        for value in expanded.decomposedStringWithCompatibilityMapping.unicodeScalars {
            switch value.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                if !value.properties.isAlphabetic { continue }
            default: break
            }
            if value.properties.numericType == .decimal, let number = value.properties.numericValue,
               number >= 0, number <= 9, number.rounded() == number {
                result.append(String(Int(number)))
            } else { result.unicodeScalars.append(value) }
        }
        return caseSensitive ? result : result.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
