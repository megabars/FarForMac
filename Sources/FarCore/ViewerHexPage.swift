import Foundation

public enum ViewerHexLayout {
    public static let defaultBytesPerRow = 16
    static let bytesPerStripe = 8
    static let maximumBytesPerRow = 1_000

    static func byteColumn(_ index: Int) -> Int { index * 3 + index / bytesPerStripe * 2 }

    public static func adjustedBytesPerRow(_ current: Int, by change: Int, columns: Int, encoding: ViewerEncoding) -> Int {
        guard (bytesPerStripe...maximumBytesPerRow).contains(current),
              change == -16 || change == -1 || change == 1 || change == 16 else { return current }
        let step = abs(change), unit = encoding == .utf16LE || encoding == .utf16BE ? 2 : 1
        let stripeWidth = 26 + bytesPerStripe / unit
        let available = min(10_000, max(0, columns)) - 11
        let stripes = max(0, available / stripeWidth)
        let remainder = available - stripes * stripeWidth - 2
        let fitted = max(bytesPerStripe, stripes * bytesPerStripe + 2 * remainder / (6 + 2 / unit))
        let maximum = min(maximumBytesPerRow, fitted) / step * step
        let minimum = max(step, bytesPerStripe)
        guard maximum >= minimum else { return current }
        let next = change > 0 ? (current / step + 1) * step : (current - 1) / step * step
        return min(maximum, max(minimum, next))
    }
}

public struct ViewerHexPage: Sendable {
    public let text: String
    public let startOffset: Int64
    public let endOffset: Int64
    public let bytesPerRow: Int
    let textLength: Int
    let unitSize: Int
    let rows: [Row]

    struct Row: Sendable {
        let start: Int
        let hexStart: Int
        let decodedStart: Int
        let cellEnds: [Int]
    }

    public func byteOffset(forUTF16 index: Int) -> Int64 {
        guard index > 0 else { return startOffset }
        guard index < textLength, !rows.isEmpty else { return endOffset }
        var low = 0, high = rows.count
        while low + 1 < high {
            let middle = low + (high - low) / 2
            if rows[middle].start <= index { low = middle } else { high = middle }
        }
        let row = rows[low]
        let byte: Int
        if index < row.hexStart { byte = 0 }
        else if index < row.decodedStart - 1 {
            let column = index - row.hexStart
            byte = column / 26 * ViewerHexLayout.bytesPerStripe + column % 26 / 3
        } else if index < row.decodedStart { byte = 0 }
        else {
            let relative = index - row.decodedStart
            byte = (row.cellEnds.firstIndex { $0 > relative } ?? row.cellEnds.count) * unitSize
        }
        let relative = Int64(low * bytesPerRow + min(bytesPerRow, byte))
        return startOffset + min(endOffset - startOffset, relative)
    }

    public func utf16Range(forByteRange range: Range<Int64>) -> NSRange? {
        guard range.lowerBound >= startOffset, range.upperBound <= endOffset else { return nil }
        func position(_ byte: Int64) -> Int {
            if byte == endOffset { return textLength }
            let relative = Int(byte - startOffset), row = rows[relative / bytesPerRow]
            return row.hexStart + ViewerHexLayout.byteColumn(relative % bytesPerRow)
        }
        let start = position(range.lowerBound)
        let end = range.isEmpty ? start : position(range.upperBound - 1) + 2
        return NSRange(location: start, length: end - start)
    }
}
