import Foundation

/// Captures the precise input range before an asynchronous invocation. Later
/// selection changes cannot redirect the result to another part of the buffer.
public struct ExtensionEditorSnapshot: Sendable {
    public enum Scope: Sendable { case document, selectionOrWord, selectedLines }
    public static let wordDividers = " \t\r\n~!%^&*()+|{}:\"<>?`-=\\[];',./#"
    public let originalText: String
    public let range: NSRange
    public var text: String { (originalText as NSString).substring(with: range) }

    public init(text: String, selection: NSRange, scope: Scope) throws {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.location <= source.length,
              selection.length <= source.length - selection.location,
              Range(selection, in: text) != nil else { throw ExtensionAPIError("Invalid editor selection.") }
        func splitsSurrogate(_ offset: Int) -> Bool {
            guard offset > 0, offset < source.length else { return false }
            return (0xD800...0xDBFF).contains(source.character(at: offset - 1)) && (0xDC00...0xDFFF).contains(source.character(at: offset))
        }
        guard !splitsSurrogate(selection.location), !splitsSurrogate(NSMaxRange(selection)) else {
            throw ExtensionAPIError("Invalid editor selection.")
        }
        originalText = text
        switch scope {
        case .document: range = NSRange(location: 0, length: source.length)
        case .selectedLines:
            guard selection.length > 0 else { throw ExtensionAPIError("Для Align выделите строки для форматирования.") }
            // Exclude the next line when selection ends exactly at its beginning.
            let last = selection.location + selection.length - 1
            let firstLine = source.lineRange(for: NSRange(location: selection.location, length: 0))
            let lastLine = source.lineRange(for: NSRange(location: last, length: 0))
            range = NSRange(location: firstLine.location, length: NSMaxRange(lastLine) - firstLine.location)
        case .selectionOrWord:
            if selection.length > 0 { range = selection; return }
            let line = source.lineRange(for: selection)
            let body = source.substring(with: line)
            let scalars = Array(body.unicodeScalars)
            let offsets = scalars.reduce(into: [0]) { $0.append($0.last! + $1.utf16.count) }
            let position = selection.location - line.location
            let cursor = offsets.firstIndex(of: position) ?? scalars.count
            let candidates = scalars.indices.filter { !Self.wordDividers.unicodeScalars.contains(scalars[$0]) }
            // Nearest word on this line; ties choose the left, as EditCase does.
            guard let nearest = candidates.min(by: {
                let lhs = abs(offsets[$0] - position), rhs = abs(offsets[$1] - position)
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }) else { range = selection; return }
            let index = candidates.contains(cursor) ? cursor : nearest
            var start = index, end = index + 1
            while start > 0, !Self.wordDividers.unicodeScalars.contains(scalars[start - 1]) { start -= 1 }
            while end < scalars.count, !Self.wordDividers.unicodeScalars.contains(scalars[end]) { end += 1 }
            range = NSRange(location: line.location + offsets[start], length: offsets[end] - offsets[start])
        }
    }

    public func replacing(with replacement: String, currentText: String) throws -> String {
        guard currentText == originalText else { throw ExtensionAPIError("Документ изменился. Повторите запуск расширения.") }
        return (originalText as NSString).replacingCharacters(in: range, with: replacement)
    }
}
