import Foundation

public struct EditorAutoWrapSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var rightMargin = 75
    public var includeMasks = "*.*"
    public var excludeMasks = ""

    public init() {}
}

public enum EditorAutoWrap {
    public struct Baseline: Equatable, Sendable {
        public let line: Int
        public let length: Int
        public init(line: Int, length: Int) { self.line = line; self.length = length }
    }

    public static func wrapAfterInput(in text: String, caret: Int, previous: Baseline, rightMargin: Int,
                                      tabSize: Int, autoIndent: Bool, fallbackEOL: String,
                                      requireSameLine: Bool = true) throws -> EditorEdit? {
        guard (0...999).contains(rightMargin), (1...64).contains(tabSize) else { return nil }
        let coordinates = FarEditorCoordinates(text)
        let position = coordinates.position(caret)
        let line = coordinates.lines[position.line - 1]
        guard (!requireSameLine || position.line == previous.line), line.text.length != previous.length,
              caret == NSMaxRange(line.text), line.text.length > 1 else { return nil }
        let source = text as NSString
        let body = source.substring(with: line.text) as NSString
        let ending = line.ending.length > 0 ? source.substring(with: line.ending) : fallbackEOL
        guard ["\n", "\r\n", "\r"].contains(ending) else { return nil }
        let indentation = autoIndent ? String((body as String).prefix(while: { $0 == " " || $0 == "\t" })) : ""
        let lastContent = (0..<body.length).reversed().first { !isBlank(body.character(at: $0)) } ?? -1
        var offset = 0, prefix = "", parts: [String] = [], changes: [EditorTextChange] = []
        var generated = 0
        while let split = splitPosition(in: body, from: offset, indentation: prefix, margin: rightMargin, tabSize: tabSize) {
            guard changes.count < EditorEditing.maximumMatches else { throw EditorEditingError.operationTooLarge }
            let position = offset + split
            let trim = autoIndent && position > lastContent
            var contentEnd = position
            if trim {
                while contentEnd > offset, isBlank(body.character(at: contentEnd - 1)) { contentEnd -= 1 }
            }
            let fragment = body.substring(with: NSRange(location: offset, length: contentEnd - offset))
            generated += prefix.utf16.count + fragment.utf16.count + ending.utf16.count
            guard generated <= EditorEditing.maximumOutputUTF16 else { throw EditorEditingError.operationTooLarge }
            parts.append(prefix + fragment + ending)
            changes.append(.init(range: NSRange(location: line.text.location + contentEnd, length: position - contentEnd),
                                 replacementUTF16Length: ending.utf16.count + indentation.utf16.count))
            offset = position
            prefix = indentation
        }
        guard !changes.isEmpty else { return nil }
        parts.append(prefix + body.substring(from: offset))
        let replacement = parts.joined()
        guard coordinates.length - line.text.length + replacement.utf16.count <= EditorEditing.maximumOutputUTF16 else {
            throw EditorEditingError.operationTooLarge
        }
        return EditorEdit(text: source.replacingCharacters(in: line.text, with: replacement),
                          selection: NSRange(location: line.text.location + replacement.utf16.count, length: 0),
                          count: changes.count, changes: changes)
    }

    private static func splitPosition(in body: NSString, from start: Int, indentation: String,
                                      margin: Int, tabSize: Int) -> Int? {
        let prefix = indentation as NSString
        var column = 0, hasContent = false
        var candidate: (index: Int, hasContent: Bool)?
        for index in 0..<(prefix.length + body.length - start) {
            let unit = index < prefix.length ? prefix.character(at: index) : body.character(at: start + index - prefix.length)
            if isBlank(unit), index > 0 {
                if column < margin || candidate == nil { candidate = (index, hasContent) }
            } else if !isBlank(unit) {
                hasContent = true
            }
            column += unit == 9 ? tabSize - column % tabSize : 1
            if column >= margin, let candidate {
                // The original search prefers the last blank before the margin.
                // Without one, it falls back to the first later blank.
                guard candidate.hasContent, candidate.index >= prefix.length else { return nil }
                return candidate.index - prefix.length + 1
            }
        }
        return nil
    }

    private static func isBlank(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }
}
