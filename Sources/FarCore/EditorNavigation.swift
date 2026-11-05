import Foundation

public struct EditorTextChange: Equatable, Sendable {
    public let range: NSRange
    public let replacementUTF16Length: Int
    public init(range: NSRange, replacementUTF16Length: Int) {
        self.range = range; self.replacementUTF16Length = replacementUTF16Length
    }
    public static func difference(from old: String, to new: String, offset: Int = 0) -> Self? {
        guard old != new else { return nil }
        let before = old as NSString, after = new as NSString
        var prefix = 0
        while prefix < min(before.length, after.length), before.character(at: prefix) == after.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < min(before.length, after.length) - prefix,
              before.character(at: before.length - suffix - 1) == after.character(at: after.length - suffix - 1) { suffix += 1 }
        return Self(range: NSRange(location: offset + prefix, length: before.length - prefix - suffix),
                    replacementUTF16Length: after.length - prefix - suffix)
    }
}

public struct EditorSearchMatch: Equatable, Sendable {
    public let range: NSRange
    public let line: Int
    public let column: Int
    public let excerpt: String
}

public struct EditorSearchMatches: Equatable, Sendable {
    public let matches: [EditorSearchMatch]
    public let truncated: Bool
}

struct EditorGotoCoordinate {
    let value: UInt64?
    let relative: Int
    let percent: Bool

    init(_ expression: String, hexadecimal: Bool) throws {
        var raw = expression.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { value = nil; relative = 0; percent = false; return }
        if raw.first == "+" { relative = 1; raw.removeFirst() }
        else if raw.first == "-" { relative = -1; raw.removeFirst() }
        else { relative = 0 }
        percent = raw.last == "%"
        if percent { raw.removeLast() }
        var radix = hexadecimal ? 16 : 10
        if raw.hasPrefix("0x") { radix = 16; raw.removeFirst(2) }
        else if raw.hasPrefix("$") { radix = 16; raw.removeFirst() }
        if raw.last == "h" { radix = 16; raw.removeLast() }
        else if raw.last == "m" { radix = 10; raw.removeLast() }
        guard !raw.isEmpty, raw.unicodeScalars.allSatisfy({
            (radix == 16 ? CharacterSet(charactersIn: "0123456789abcdef") : .decimalDigits).contains($0) && $0.isASCII
        }), let parsed = UInt64(raw, radix: radix), parsed <= UInt64(Int.max) else {
            throw EditorEditingError.invalidPosition
        }
        value = parsed
    }

    static func pair(_ expression: String, hexadecimal: Bool) throws -> (Self, Self) {
        guard expression.utf16.count <= 4096 else { throw EditorEditingError.invalidPosition }
        let parts = expression.components(separatedBy: CharacterSet(charactersIn: ",.;:"))
        let values = parts.count > 1 ? parts : expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard values.count <= 2 else { throw EditorEditingError.invalidPosition }
        return (try Self(values.first ?? "", hexadecimal: hexadecimal),
                try Self(values.count > 1 ? values[1] : "", hexadecimal: hexadecimal))
    }

    func resolve(current: Int, extent: Int, maximum: Int, oneBased: Bool = true) throws -> Int {
        guard let value else { return min(maximum, max(0, current)) }
        let coordinate: Int
        if percent {
            // Saturate before multiplication; huge valid inputs clamp predictably.
            if value >= 100 { coordinate = extent }
            else { coordinate = extent / 100 * Int(value) + (extent % 100) * Int(value) / 100 }
        } else { coordinate = Int(value) }
        let target: Int
        if relative == 0 { target = percent || !oneBased ? coordinate : max(0, coordinate - 1) }
        else {
            let (sum, overflow) = current.addingReportingOverflow(relative * coordinate)
            target = overflow ? (relative > 0 ? maximum : 0) : sum
        }
        return min(maximum, max(0, target))
    }
}

/// Ten numbered, UTF-16 anchors. Edits move anchors; anchors inside replaced text
/// attach to its beginning. Reopen restores them only with a matching file identity.
public struct EditorBookmarks: Codable, Equatable, Sendable {
    private var anchors: [Int: Int] = [:]
    public init() {}
    public var slots: [Int] { anchors.keys.sorted() }
    public func offset(slot: Int) -> Int? { anchors[slot] }
    public mutating func set(slot: Int, offset: Int) {
        guard (0...9).contains(slot), offset >= 0 else { return }
        anchors[slot] = offset
    }
    public mutating func remove(slot: Int) { anchors.removeValue(forKey: slot) }
    public mutating func update(from old: String, to new: String) {
        guard !anchors.isEmpty else { return }
        if let change = EditorTextChange.difference(from: old, to: new) { apply(changes: [change]) }
    }
    public mutating func apply(changes: [EditorTextChange]) {
        for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
            applyEdit(range: change.range, replacementUTF16Length: change.replacementUTF16Length)
        }
    }
    public mutating func applyEdit(range: NSRange, replacementUTF16Length: Int) {
        guard range.location >= 0, range.length >= 0, range.location <= Int.max - range.length,
              replacementUTF16Length >= 0 else { return }
        for (slot, position) in anchors {
            if position >= NSMaxRange(range) {
                let (next, overflow) = position.addingReportingOverflow(replacementUTF16Length - range.length)
                anchors[slot] = overflow ? range.location : max(0, next)
            } else if position >= range.location { anchors[slot] = range.location }
        }
    }
}
