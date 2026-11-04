import Foundation

/// Shared Unicode word policy: letters, marks, numbers and underscore form words.
/// Only adjacent scalars are inspected, avoiding copies of long line prefixes.
enum SearchWordBoundary {
    static func isWholeWord(_ text: String, range: NSRange) -> Bool {
        let source = text as NSString
        func word(at index: Int) -> Bool {
            guard index >= 0, index < source.length else { return false }
            var start = index
            let unit = source.character(at: start)
            if (0xDC00...0xDFFF).contains(unit), start > 0 { start -= 1 }
            let first = source.character(at: start)
            let length = (0xD800...0xDBFF).contains(first) && start + 1 < source.length ? 2 : 1
            guard let scalar = source.substring(with: NSRange(location: start, length: length)).unicodeScalars.first else { return false }
            return scalar == "_" || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
        }
        return !word(at: range.location - 1) && !word(at: NSMaxRange(range))
    }
}
