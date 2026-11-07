import Foundation

/// Brackets' text behavior, independently implemented from its pinned FAR contract.
public enum EditorBrackets {
    public struct Options: Codable, Equatable, Sendable {
        public var ignoreQuoted = false
        public var ignoreAfter = false
        public var doubleFirst = true
        public var beep = false
        public var quotes = "''\"\"`'``„”"
        public var singles = "<>{}[]()\"\"''%%«»"
        public var doubles = "/**/<??><%%>"
        public init() {}
        public var isValid: Bool {
            [(quotes, 2, 20), (singles, 2, 20), (doubles, 4, 40)].allSatisfy { value, stride, limit in
                let units = Array(value.utf16)
                return units.count <= limit && units.count % stride == 0 && units.allSatisfy {
                    $0 != 0 && $0 != 10 && $0 != 13 && !(0xD800...0xDFFF).contains($0)
                }
            }
        }
    }
    public enum Direction: Sendable { case forward, backward }
    public struct Match: Equatable, Sendable {
        public let target: Int
        public let selection: NSRange
    }
    private enum Kind { case single, after, double, equal }
    private struct Candidate {
        let kind: Kind
        let pair: [UInt16]
        let direction: Int
    }

    /// A nil direction requests the original direction menu for equal symbols.
    public enum Outcome: Equatable, Sendable {
        case noMatch
        case needsDirection
        case match(Match)
    }
    public static func find(in text: String, cursor: Int, direction: Direction? = nil, options: Options = .init()) -> Outcome {
        let units = Array(text.utf16)
        guard options.isValid, cursor >= 0, cursor <= units.count else { return .noMatch }
        func at(_ i: Int) -> UInt16 { units.indices.contains(i) && units[i] != 10 && units[i] != 13 ? units[i] : 0 }
        func pairs(_ string: String, width: Int) -> [[UInt16]] {
            let value = Array(string.utf16)
            return stride(from: 0, to: value.count, by: width).map { Array(value[$0..<$0 + width]) }
        }
        let quotes = pairs(options.quotes, width: 2)
        let singles = pairs(options.singles, width: 2)
        let doubles = pairs(options.doubles, width: 4)
        let current = at(cursor), before = at(cursor - 1), after = at(cursor + 1)
        if !options.ignoreQuoted && quotes.contains(where: { $0[0] == before && $0[1] == after }) { return .noMatch }
        func single() -> Candidate? {
            for pair in singles {
                if current == pair[0] { return Candidate(kind: .single, pair: pair, direction: 1) }
                if current == pair[1] { return Candidate(kind: .single, pair: pair, direction: -1) }
            }
            if !options.ignoreAfter {
                for pair in singles {
                    if before == pair[0] { return Candidate(kind: .after, pair: pair, direction: 1) }
                    if before == pair[1] { return Candidate(kind: .after, pair: pair, direction: -1) }
                }
            }
            return nil
        }
        func double() -> Candidate? {
            for pair in doubles where pair.contains(current) {
                if (current == pair[0] && after == pair[1]) || (before == pair[0] && current == pair[1]) {
                    return Candidate(kind: .double, pair: pair, direction: 1)
                }
                if (before == pair[2] && current == pair[3]) || (current == pair[2] && after == pair[3]) {
                    return Candidate(kind: .double, pair: pair, direction: -1)
                }
                // OpenW stops at the first double description containing this symbol.
                break
            }
            return nil
        }
        guard var candidate = options.doubleFirst ? (double() ?? single()) : (single() ?? double()) else { return .noMatch }
        let pair = candidate.pair
        if pair[0] == pair[1] {
            guard let direction else { return .needsDirection }
            candidate = Candidate(kind: .equal, pair: pair, direction: direction == .forward ? 1 : -1)
        }
        var index = cursor + candidate.direction
        var depth = 1
        while units.indices.contains(index) {
            defer { index += candidate.direction }
            let value = at(index), left = at(index - 1), right = at(index + 1)
            if value == 0 { continue }
            if options.ignoreQuoted && quotes.contains(where: { $0[0] == left && $0[1] == right }) { continue }
            var found = false
            switch candidate.kind {
            case .equal:
                found = value == current && (before == 92) == (left == 92)
            case .single, .after:
                let initial = candidate.kind == .after ? before : current
                if value == initial { depth += 1 }
                else if (value == pair[0] && initial == pair[1]) || (value == pair[1] && initial == pair[0]) {
                    depth -= 1
                    found = depth == (candidate.kind == .after && candidate.direction < 0 ? 1 : 0)
                }
            case .double:
                let origin = candidate.direction > 0 ? 0 : 2
                let opening = (current == pair[origin] && value == pair[origin] && right == pair[origin + 1]) ||
                    (current == pair[origin + 1] && value == pair[origin + 1] && left == pair[origin])
                if opening { depth += 1 }
                else {
                    // FAR checks every mirrored role even for overlapping pairs
                    // such as /* and */. Direction does not restrict this test.
                    let roles = [(0, 2, true), (1, 3, false), (2, 0, true), (3, 1, false)]
                    let closing = roles.contains { initial, target, leading in
                        current == pair[initial] && value == pair[target] &&
                        (leading ? after == pair[initial + 1] && right == pair[target + 1]
                                 : before == pair[initial - 1] && left == pair[target - 1])
                    }
                    if closing { depth -= 1; found = depth == 0 }
                }
            }
            if found {
                var target = index
                if candidate.kind == .double {
                    target += (current == pair[0] || current == pair[3]) ? candidate.direction : -candidate.direction
                }
                var start = min(cursor, target), end = max(cursor, target) + 1
                if candidate.kind == .after {
                    if candidate.direction > 0 { start -= 1 } else { end -= 1 }
                }
                guard target >= 0, target <= units.count, start >= 0, end <= units.count else { return .noMatch }
                return .match(Match(target: target, selection: NSRange(location: start, length: end - start)))
            }
        }
        return .noMatch
    }
}
