import Foundation

public struct ShellPromptStyle: Equatable, Sendable {
    public var foreground: TerminalColor?
    public var background: TerminalColor?
    public var underlineColor: TerminalColor?
    public var styles: Set<String> = []
}

public struct ShellPromptSegment: Equatable, Sendable {
    public var text: String
    public let style: ShellPromptStyle
    let collapsible: Bool
}

public struct ShellPrompt: Equatable, Sendable {
    public let segments: [ShellPromptSegment]
    public let maximumWidthPercent: Int

    public static func render(_ format: String, directory: URL, environment: [String: String] = [:],
                              stackDepth: Int = 0, networkPath: String? = nil, isAdministrator: Bool = false,
                              administratorLabel: String = "Administrator", now: Date = Date()) -> ShellPrompt {
        var source = Substring(format.prefix(4_096)), segments: [ShellPromptSegment] = []
        var style = ShellPromptStyle(), width = 50, remaining = 16_384
        func append(_ value: String, collapsible: Bool = false) {
            guard remaining > 0 else { return }
            let safe = value.prefix(remaining).unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            guard !safe.isEmpty else { return }
            remaining -= safe.count
            if let last = segments.last, !collapsible, !last.collapsible, last.style == style {
                segments[segments.count - 1].text += safe
            } else {
                segments.append(.init(text: safe, style: style, collapsible: collapsible))
            }
        }
        func text(_ literal: String) {
            var input = Substring(expandEnvironment(literal, environment: environment))
            while let first = input.first {
                input = input.dropFirst()
                guard first == "$", let code = input.first else { append(String(first)); continue }
                input = input.dropFirst()
                switch code.uppercased() {
                case "A": append("&")
                case "B": append("|")
                case "C": append("(")
                case "F": append(")")
                case "G": append(">")
                case "L": append("<")
                case "Q": append("=")
                case "S": append(" ")
                case "$": append("$")
                case "H":
                    if let index = segments.lastIndex(where: { !$0.text.isEmpty }) {
                        segments[index].text.removeLast()
                        if segments[index].text.isEmpty { segments.remove(at: index) }
                    }
                case "P": append(directory.path, collapsible: true)
                case "W": append(directory.lastPathComponent, collapsible: true)
                case "M": if let networkPath { append(networkPath, collapsible: true) }
                case "N": append("?")
                case "+": append(String(repeating: "+", count: max(0, min(4_096, stackDepth))))
                case "D": append(DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .none))
                case "T":
                    let time = DateFormatter()
                    time.locale = Locale(identifier: "en_US_POSIX")
                    time.dateFormat = "HH:mm:ss"
                    append(time.string(from: now))
                case "#":
                    let digits = input.prefix(while: { $0.isASCII && $0.isNumber })
                    if let percent = Int(digits) { width = percent == 0 ? 50 : max(5, min(95, percent)) }
                    input = input.dropFirst(digits.count)
                case "@":
                    let delimiters = input.prefix(2)
                    if isAdministrator, delimiters.count == 2 {
                        append(String(delimiters.first!) + administratorLabel + String(delimiters.last!))
                    }
                    input = input.dropFirst(delimiters.count)
                default: break
                }
            }
        }

        while let open = colorStart(in: source) {
            let afterOpen = source.index(after: open)
            guard let close = source[afterOpen...].firstIndex(of: ")") else { break }
            text(String(source[..<open]))
            let content = source[afterOpen..<close]
            if let parsed = parseStyle(content) { style = parsed }
            else { text(String(source[open...close])) }
            source = source[source.index(after: close)...]
        }
        text(String(source))
        return .init(segments: segments, maximumWidthPercent: width)
    }

    /// Long directory segments collapse first, preserving the visible prompt
    /// delimiter whenever it fits. The width uses the terminal's cell model.
    public func fitted(to columns: Int) -> [ShellPromptSegment] {
        let limit = max(0, min(10_000, columns)) * maximumWidthPercent / 100
        let fixed = segments.filter { !$0.collapsible }.reduce(0) { $0 + Self.cellWidth($1.text) }
        let collapsed = segments.filter(\.collapsible).count
        let total = segments.reduce(0) { $0 + Self.cellWidth($1.text) }
        let pathWidth = total > limit && collapsed > 0 ? max(0, limit - fixed) / collapsed : limit
        var remaining = limit
        var result: [ShellPromptSegment] = []
        for var segment in segments where remaining > 0 {
            segment.text = Self.collapse(segment.text, to: segment.collapsible ? min(pathWidth, remaining) : remaining)
            if !segment.text.isEmpty {
                remaining -= Self.cellWidth(segment.text)
                result.append(segment)
            }
        }
        return result
    }

    private static func cellWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + TerminalGraphemeWidth.width(String($1)) }
    }

    private static func collapse(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard cellWidth(text) > limit else { return text }
        let front = (limit - 1) / 2, back = limit - 1 - front
        func portion<S: Sequence>(_ characters: S, limit: Int) -> String where S.Element == Character {
            var result = "", remaining = limit
            for character in characters {
                let width = TerminalGraphemeWidth.width(String(character))
                guard width <= remaining else { break }
                result.append(character)
                remaining -= width
            }
            return result
        }
        return portion(text, limit: front) + "…" + String(portion(text.reversed(), limit: back).reversed())
    }

    private static func colorStart(in source: Substring) -> String.Index? {
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "(" { return index }
            if source[index] == "$" {
                let next = source.index(after: index)
                if next < source.endIndex {
                    index = source.index(after: next)
                    if source[next] == "@" { index = source.index(index, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex }
                    continue
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func expandEnvironment(_ source: String, environment: [String: String]) -> String {
        var remainder = source[...], result = ""
        while let open = remainder.firstIndex(of: "%") {
            result += remainder[..<open]
            let start = remainder.index(after: open)
            guard let close = remainder[start...].firstIndex(of: "%") else { return result + remainder[open...] }
            let name = String(remainder[start..<close])
            let after = remainder.index(after: close)
            let value = environment[name] ?? environment.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            result += value.map { String($0.prefix(4_096)) } ?? String(remainder[open..<after])
            if result.count >= 8_192 { return String(result.prefix(8_192)) }
            remainder = remainder[after...]
        }
        return result + remainder
    }

    private static func parseStyle(_ value: Substring) -> ShellPromptStyle? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 4 else { return nil }
        var result = ShellPromptStyle()
        func color(_ part: Substring) -> TerminalColor? {
            if part.first == "T" || part.first == "t" {
                let hex = part.dropFirst()
                guard hex.count <= 8, let number = UInt32(hex, radix: 16) else { return nil }
                return .rgb(UInt8(truncatingIfNeeded: number >> 16), UInt8(truncatingIfNeeded: number >> 8), UInt8(truncatingIfNeeded: number))
            }
            guard let index = UInt8(part, radix: 16) else { return nil }
            let remap: [UInt8] = [0, 4, 2, 6, 1, 5, 3, 7, 8, 12, 10, 14, 9, 13, 11, 15]
            return .indexed(index < 16 ? remap[Int(index)] : index)
        }
        for (index, part) in parts.enumerated() where !part.isEmpty {
            if index == 2 {
                let styles = Set(part.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
                let supported: Set<String> = ["bold", "italic", "overline", "strikeout", "faint", "blink", "inverse", "invisible",
                    "underline", "underline_double", "underline_curly", "underline_dot", "underline_dash"]
                guard styles.isSubset(of: supported) else { return nil }
                result.styles = styles
            } else {
                guard let tint = color(part) else { return nil }
                switch index {
                case 0: result.foreground = tint
                case 1: result.background = tint
                default: result.underlineColor = tint
                }
            }
        }
        return result
    }
}
