import Foundation
import Darwin

public enum ViewerEncoding: String, CaseIterable, Codable, Sendable {
    case automatic, utf8, utf16LE, utf16BE, windows1251, windows1252, latin1
    public var title: String {
        switch self {
        case .automatic: return "Автоматически"
        case .utf8: return "UTF-8"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .windows1251: return "Windows-1251"
        case .windows1252: return "Windows-1252"
        case .latin1: return "ISO-8859-1"
        }
    }
}

public enum ViewerDisplayMode: Int, Codable, Sendable {
    case text, hex, dump
}

public enum ViewerError: Error, LocalizedError, Equatable {
    case notRegularFile, unsupportedURL, changedFile, invalidRange, cancelled, lineNotFound
    case io(String)
    public var errorDescription: String? {
        switch self {
        case .notRegularFile: return "Просмотр доступен только для обычных файлов."
        case .unsupportedURL: return "Источник не поддерживается."
        case .changedFile: return "Файл изменился. Откройте его заново."
        case .invalidRange: return "Недопустимое смещение или размер блока."
        case .cancelled: return "Операция отменена."
        case .lineNotFound: return "Строка не найдена."
        case .io(let message): return message
        }
    }
}

public final class ViewerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Immutable random-access snapshot. Future remote and archive providers implement
/// this boundary without exposing writable handles to the viewer.
public protocol ViewerByteSource: Sendable {
    var size: Int64 { get }
    var identity: String { get }
    func read(offset: Int64, count: Int) throws -> Data
    func verifyUnchanged() throws
}

public final class LocalViewerSource: ViewerByteSource, @unchecked Sendable {
    public static let maximumReadCount = 65_544
    public let size: Int64
    public let identity: String
    public let url: URL
    private let originalURL: URL
    private let descriptor: Int32
    private let snapshot: Snapshot

    private struct Snapshot: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size; mode = info.st_mode
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    public init(url: URL) throws {
        guard url.isFileURL else { throw ViewerError.unsupportedURL }
        let original = url.standardizedFileURL
        let resolved = original.resolvingSymlinksInPath()
        // Nonblocking is essential: opening a FIFO must never wait for a writer.
        let fd = open(resolved.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw ViewerError.io(String(cString: strerror(errno))) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let message = String(cString: strerror(errno)); close(fd); throw ViewerError.io(message)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { close(fd); throw ViewerError.notRegularFile }
        descriptor = fd; self.url = resolved; originalURL = original
        snapshot = Snapshot(info); size = Int64(info.st_size)
        identity = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        try verifyUnchanged()
    }
    deinit { close(descriptor) }

    public func verifyUnchanged() throws {
        var opened = stat(), current = stat()
        guard fstat(descriptor, &opened) == 0, stat(originalURL.path, &current) == 0,
              Snapshot(opened) == snapshot, Snapshot(current) == snapshot else { throw ViewerError.changedFile }
    }

    public func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset <= size, count >= 0, count <= Self.maximumReadCount else { throw ViewerError.invalidRange }
        try verifyUnchanged()
        let length = Int(min(Int64(count), size - offset))
        var data = Data(count: length)
        if length > 0 {
            try data.withUnsafeMutableBytes { raw in
                var done = 0
                while done < length {
                    let result = pread(descriptor, raw.baseAddress!.advanced(by: done), length - done, off_t(offset + Int64(done)))
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw ViewerError.io(String(cString: strerror(errno)))
                    }
                    guard result > 0 else { throw ViewerError.changedFile }
                    done += result
                }
            }
        }
        try verifyUnchanged()
        return data
    }
}

public struct ViewerPage: Sendable {
    public let text: String
    public let startOffset: Int64
    public let endOffset: Int64
    public let invalidSequences: Bool
    fileprivate let spans: [Span]
    fileprivate struct Span: Sendable {
        let bytes: Range<Int64>
        let utf16: Range<Int>
    }

    public func byteOffset(forUTF16 index: Int) -> Int64 {
        guard index > 0 else { return startOffset }
        guard index < (spans.last?.utf16.upperBound ?? 0) else { return endOffset }
        var low = 0, high = spans.count
        while low < high {
            let middle = low + (high - low) / 2
            if spans[middle].utf16.upperBound <= index { low = middle + 1 }
            else { high = middle }
        }
        return low < spans.count ? spans[low].bytes.lowerBound : endOffset
    }

    /// Maps overlapping bytes to complete scalars, including a full surrogate pair.
    public func utf16Range(forByteRange range: Range<Int64>) -> NSRange? {
        guard range.lowerBound >= startOffset, range.upperBound <= endOffset else { return nil }
        let first = spanIndex(containingOrFollowing: range.lowerBound)
        if range.isEmpty {
            let index = first < spans.count ? spans[first].utf16.lowerBound : (spans.last?.utf16.upperBound ?? 0)
            return NSRange(location: index, length: 0)
        }
        let last = spanIndex(containingOrFollowing: range.upperBound - 1)
        guard first < spans.count, last < spans.count else { return nil }
        return NSRange(location: spans[first].utf16.lowerBound,
                       length: spans[last].utf16.upperBound - spans[first].utf16.lowerBound)
    }

    private func spanIndex(containingOrFollowing offset: Int64) -> Int {
        var low = 0, high = spans.count
        while low < high {
            let middle = low + (high - low) / 2
            if spans[middle].bytes.upperBound <= offset { low = middle + 1 }
            else { high = middle }
        }
        return low
    }

}

public struct ViewerDocument: Sendable {
    public let source: any ViewerByteSource
    public let encoding: ViewerEncoding
    public let bomLength: Int
    public var size: Int64 { source.size }
    public static let maximumPageByteCount = 65_536

    public init(source: any ViewerByteSource, encoding requested: ViewerEncoding = .automatic) throws {
        self.source = source
        try source.verifyUnchanged()
        let sample = Array(try source.read(offset: 0, count: Int(min(source.size, 65_536))))
        let detectedBOM: (ViewerEncoding, Int)?
        if sample.starts(with: [0xEF, 0xBB, 0xBF]) { detectedBOM = (.utf8, 3) }
        else if sample.starts(with: [0xFF, 0xFE]) { detectedBOM = (.utf16LE, 2) }
        else if sample.starts(with: [0xFE, 0xFF]) { detectedBOM = (.utf16BE, 2) }
        else { detectedBOM = nil }
        if requested != .automatic {
            encoding = requested; bomLength = detectedBOM?.0 == requested ? detectedBOM!.1 : 0
        } else if let bom = detectedBOM {
            encoding = bom.0; bomLength = bom.1
        } else {
            bomLength = 0
            // Null parity recognizes ordinary BOM-less UTF-16 text; legacy code
            // pages are intrinsically ambiguous and can always be selected explicitly.
            let pairs = sample.count / 2
            let evenZeros = stride(from: 0, to: pairs * 2, by: 2).filter { sample[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: pairs * 2, by: 2).filter { sample[$0] == 0 }.count
            if pairs >= 2, oddZeros * 3 > pairs, evenZeros * 10 < pairs { encoding = .utf16LE }
            else if pairs >= 2, evenZeros * 3 > pairs, oddZeros * 10 < pairs { encoding = .utf16BE }
            else {
                var i = 0, valid = true
                while i < sample.count {
                    let scalar = Self.decode(sample, at: i, encoding: .utf8)
                    // A bounded sample may end inside a valid sequence.
                    if !scalar.valid, Int64(sample.count) < source.size, Self.isIncompleteUTF8(sample, at: i) { break }
                    if !scalar.valid { valid = false; break }
                    i += scalar.length
                }
                encoding = valid ? .utf8 : .windows1252
            }
        }
        try source.verifyUnchanged()
    }

    public func page(at offset: Int64, byteCount: Int = 65_536) throws -> ViewerPage {
        guard offset >= 0, offset <= size, byteCount > 0 else { throw ViewerError.invalidRange }
        try source.verifyUnchanged()
        if offset == size {
            return ViewerPage(text: "", startOffset: size, endOffset: size, invalidSequences: false, spans: [])
        }
        let requested = max(Int64(bomLength), offset)
        let contextStart = max(Int64(bomLength), requested - 4)
        let count = Int(min(size - contextStart, Int64(min(byteCount, Self.maximumPageByteCount)) + requested - contextStart + 4))
        let bytes = Array(try source.read(offset: contextStart, count: count))
        var index = Int(requested - contextStart)
        if encoding == .utf16LE || encoding == .utf16BE {
            index -= Int((contextStart + Int64(index) - Int64(bomLength)) % 2)
            if index >= 2, index + 1 < bytes.count {
                let unit = Self.word(bytes, index, encoding)
                let previous = Self.word(bytes, index - 2, encoding)
                if (0xDC00...0xDFFF).contains(unit), (0xD800...0xDBFF).contains(previous) { index -= 2 }
            }
        } else if encoding == .utf8, index < bytes.count {
            // Align only when an actual valid scalar surrounds the target.
            for candidate in max(0, index - 3)..<index {
                let scalar = Self.decode(bytes, at: candidate, encoding: encoding)
                if scalar.valid, candidate + scalar.length > index { index = candidate; break }
            }
        }
        let start = contextStart + Int64(index)
        let limit = start + min(Int64(min(byteCount, Self.maximumPageByteCount)), size - start)
        var scalars = String.UnicodeScalarView(), spans: [ViewerPage.Span] = [], invalid = false, utf16 = 0
        while index < bytes.count, contextStart + Int64(index) < limit {
            let scalar = Self.decode(bytes, at: index, encoding: encoding)
            let width = scalar.value > 0xFFFF ? 2 : 1
            scalars.append(Unicode.Scalar(scalar.value)!)
            spans.append(.init(bytes: (contextStart + Int64(index))..<(contextStart + Int64(index + scalar.length)), utf16: utf16..<(utf16 + width)))
            invalid = invalid || !scalar.valid; index += scalar.length; utf16 += width
        }
        try source.verifyUnchanged()
        return ViewerPage(text: String(scalars), startOffset: start, endOffset: contextStart + Int64(index), invalidSequences: invalid, spans: spans)
    }

    /// FAR dump has one cell per encoding unit, not a hex address/byte table.
    /// UTF-8 continuation bytes occupy visible `›` cells. Controls are inert
    /// pictures, so AppKit cannot interpret a file's newline, tab or bidi controls.
    /// Rows use a fixed cell count; display width of non-BMP / wide glyphs remains
    /// a font-dependent macOS adaptation rather than console-cell equivalence.
    public func dumpPage(at offset: Int64, byteCount: Int = 65_536, columns: Int = 80) throws -> ViewerPage {
        guard offset >= 0, offset <= size, byteCount > 0, (1...1_000).contains(columns) else { throw ViewerError.invalidRange }
        try source.verifyUnchanged()
        let unitSize = encoding == .utf16LE || encoding == .utf16BE ? 2 : 1
        let start = offset == size ? size : offset / Int64(unitSize) * Int64(unitSize)
        let budget = min(byteCount, Self.maximumPageByteCount)
        let length = min(size - start, Int64(max(unitSize, budget / unitSize * unitSize)))
        let end = start + length
        let contextStart = max(0, start - 3)
        let bytes = Array(try source.read(offset: contextStart, count: Int(min(size - contextStart, length + (start - contextStart) + 3))))
        var output = String.UnicodeScalarView(), spans: [ViewerPage.Span] = [], invalid = false
        var index = Int(start - contextStart), utf16 = 0, cells = 0
        func append(_ scalar: UInt32, bytes range: Range<Int64>) {
            output.append(Unicode.Scalar(scalar)!)
            let width = scalar > 0xFFFF ? 2 : 1
            spans.append(.init(bytes: range, utf16: utf16..<(utf16 + width)))
            utf16 += width
        }
        while index < Int(end - contextStart) {
            let position = contextStart + Int64(index)
            if cells > 0, cells % columns == 0 { append(10, bytes: position..<position) }
            var value: UInt32
            if unitSize == 2 {
                if index + 1 < bytes.count {
                    let unit = Self.word(bytes, index, encoding)
                    if (0xD800...0xDBFF).contains(unit), index + 3 < bytes.count,
                       (0xDC00...0xDFFF).contains(Self.word(bytes, index + 2, encoding)) {
                        value = Self.decode(bytes, at: index, encoding: encoding).value
                    } else if (0xDC00...0xDFFF).contains(unit), index >= 2,
                              (0xD800...0xDBFF).contains(Self.word(bytes, index - 2, encoding)) {
                        value = 0x203A
                    } else if (0xD800...0xDFFF).contains(unit) { value = 0xFFFD; invalid = true }
                    else { value = unit }
                } else { value = 0xFFFD; invalid = true }
            } else if encoding == .utf8 {
                let continuation = (max(0, index - 3)..<index).contains { candidate in
                    let scalar = Self.decode(bytes, at: candidate, encoding: .utf8)
                    return scalar.valid && candidate + scalar.length > index
                }
                if continuation { value = 0x203A }
                else {
                    let scalar = Self.decode(bytes, at: index, encoding: encoding)
                    value = scalar.value; invalid = invalid || !scalar.valid
                }
            } else {
                let scalar = Self.decode(bytes, at: index, encoding: encoding)
                value = scalar.value; invalid = invalid || !scalar.valid
            }
            if value < 32 { value += 0x2400 }
            else if value == 127 { value = 0x2421 }
            else if (0x80...0x9F).contains(value) || value == 0x2028 || value == 0x2029 ||
                        Unicode.Scalar(value)!.properties.generalCategory == .format {
                value = 0xFFFD
            }
            append(value, bytes: position..<(position + min(end - position, Int64(unitSize))))
            index += unitSize; cells += 1
        }
        try source.verifyUnchanged()
        return ViewerPage(text: String(output), startOffset: start, endOffset: end, invalidSequences: invalid, spans: spans)
    }

    /// Linear, bounded-memory scan. Lines are one-based; CRLF is one separator.
    public func offset(ofLine target: Int64, cancellation: ViewerCancellation = ViewerCancellation(), onProgress: (Int64) -> Void = { _ in }) throws -> Int64 {
        guard target >= 1 else { throw ViewerError.invalidRange }
        if cancellation.isCancelled { throw ViewerError.cancelled }
        try source.verifyUnchanged()
        if target == 1 { return Int64(bomLength) }
        var line: Int64 = 1, result: Int64?
        try scan(until: size, cancellation: cancellation, onProgress: onProgress) { _, end, value in
            if Self.isSeparator(value) { line += 1; if line == target { result = end; return false } }
            return true
        }
        guard let result else { throw ViewerError.lineNotFound }
        return result
    }

    public func lineNumber(at offset: Int64, cancellation: ViewerCancellation = ViewerCancellation(), onProgress: (Int64) -> Void = { _ in }) throws -> Int64 {
        guard offset >= 0, offset <= size else { throw ViewerError.invalidRange }
        var line: Int64 = 1
        try scan(until: offset, cancellation: cancellation, onProgress: onProgress) { _, end, value in
            if end <= offset, Self.isSeparator(value) { line += 1 }
            return true
        }
        return line
    }

    // Delay CR until the next scalar so CRLF produces one complete byte range,
    // even when the pair straddles pages.
    private func scan(until limit: Int64, cancellation: ViewerCancellation, onProgress: (Int64) -> Void, visit: (Int64, Int64, UInt32) -> Bool) throws {
        var offset = Int64(bomLength), pendingCR: (Int64, Int64)?
        try source.verifyUnchanged()
        while offset < size, offset < limit || pendingCR != nil {
            if cancellation.isCancelled { throw ViewerError.cancelled }
            let block = try page(at: offset)
            for (scalar, span) in zip(block.text.unicodeScalars, block.spans) {
                if cancellation.isCancelled { throw ViewerError.cancelled }
                if let cr = pendingCR {
                    pendingCR = nil
                    if scalar.value == 10 {
                        if !visit(cr.0, span.bytes.upperBound, 13) { try source.verifyUnchanged(); return }
                        continue
                    }
                    if !visit(cr.0, cr.1, 13) { try source.verifyUnchanged(); return }
                }
                if span.bytes.lowerBound >= limit { try source.verifyUnchanged(); return }
                if scalar.value == 13 { pendingCR = (span.bytes.lowerBound, span.bytes.upperBound) }
                else if !visit(span.bytes.lowerBound, span.bytes.upperBound, scalar.value) { try source.verifyUnchanged(); return }
            }
            guard block.endOffset > offset else { throw ViewerError.invalidRange }
            offset = block.endOffset; onProgress(min(offset, limit))
        }
        if let cr = pendingCR { _ = visit(cr.0, cr.1, 13) }
        if cancellation.isCancelled { throw ViewerError.cancelled }
        try source.verifyUnchanged()
    }

    private static func isIncompleteUTF8(_ bytes: [UInt8], at i: Int) -> Bool {
        let length: Int
        switch bytes[i] {
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default: return false
        }
        guard i + length > bytes.count else { return false }
        return bytes[(i + 1)...].allSatisfy { $0 & 0xC0 == 0x80 }
    }

    private static func isSeparator(_ value: UInt32) -> Bool { [10, 13, 0x85, 0x2028, 0x2029].contains(value) }
    private static func word(_ bytes: [UInt8], _ i: Int, _ encoding: ViewerEncoding) -> UInt32 {
        encoding == .utf16LE ? UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 : UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
    }
    private struct Scalar { let value: UInt32; let length: Int; let valid: Bool }
    private static func decode(_ bytes: [UInt8], at i: Int, encoding: ViewerEncoding) -> Scalar {
        let first = bytes[i]
        if encoding == .utf16LE || encoding == .utf16BE {
            guard i + 1 < bytes.count else { return Scalar(value: 0xFFFD, length: 1, valid: false) }
            let value = word(bytes, i, encoding)
            if (0xD800...0xDBFF).contains(value) {
                guard i + 3 < bytes.count else { return Scalar(value: 0xFFFD, length: 2, valid: false) }
                let low = word(bytes, i + 2, encoding)
                guard (0xDC00...0xDFFF).contains(low) else { return Scalar(value: 0xFFFD, length: 2, valid: false) }
                return Scalar(value: 0x10000 + (value - 0xD800) * 0x400 + low - 0xDC00, length: 4, valid: true)
            }
            return Scalar(value: (0xDC00...0xDFFF).contains(value) ? 0xFFFD : value, length: 2, valid: !(0xDC00...0xDFFF).contains(value))
        }
        if encoding == .latin1 { return Scalar(value: UInt32(first), length: 1, valid: true) }
        if encoding == .windows1251 || encoding == .windows1252 {
            let value: UInt32
            if first < 0x80 { value = UInt32(first) }
            else if encoding == .windows1251 { value = cp1251[Int(first) - 128] }
            else if first < 0xA0 { value = cp1252[Int(first) - 128] }
            else { value = UInt32(first) }
            return Scalar(value: value, length: 1, valid: value != 0xFFFD)
        }
        if first < 0x80 { return Scalar(value: UInt32(first), length: 1, valid: true) }
        let length: Int, minimum: UInt32, mask: UInt8
        switch first {
        case 0xC2...0xDF: length = 2; minimum = 0x80; mask = 0x1F
        case 0xE0...0xEF: length = 3; minimum = 0x800; mask = 0x0F
        case 0xF0...0xF4: length = 4; minimum = 0x10000; mask = 0x07
        default: return Scalar(value: 0xFFFD, length: 1, valid: false)
        }
        guard i + length <= bytes.count else { return Scalar(value: 0xFFFD, length: 1, valid: false) }
        var value = UInt32(first & mask)
        for j in 1..<length {
            guard bytes[i + j] & 0xC0 == 0x80 else { return Scalar(value: 0xFFFD, length: 1, valid: false) }
            value = value << 6 | UInt32(bytes[i + j] & 0x3F)
        }
        guard value >= minimum, value <= 0x10FFFF, !(0xD800...0xDFFF).contains(value) else { return Scalar(value: 0xFFFD, length: 1, valid: false) }
        return Scalar(value: value, length: length, valid: true)
    }

    private static let cp1252: [UInt32] = [
        0x20AC,0xFFFD,0x201A,0x0192,0x201E,0x2026,0x2020,0x2021,0x02C6,0x2030,0x0160,0x2039,0x0152,0xFFFD,0x017D,0xFFFD,
        0xFFFD,0x2018,0x2019,0x201C,0x201D,0x2022,0x2013,0x2014,0x02DC,0x2122,0x0161,0x203A,0x0153,0xFFFD,0x017E,0x0178
    ]
    private static let cp1251: [UInt32] = [
        0x0402,0x0403,0x201A,0x0453,0x201E,0x2026,0x2020,0x2021,0x20AC,0x2030,0x0409,0x2039,0x040A,0x040C,0x040B,0x040F,
        0x0452,0x2018,0x2019,0x201C,0x201D,0x2022,0x2013,0x2014,0xFFFD,0x2122,0x0459,0x203A,0x045A,0x045C,0x045B,0x045F,
        0x00A0,0x040E,0x045E,0x0408,0x00A4,0x0490,0x00A6,0x00A7,0x0401,0x00A9,0x0404,0x00AB,0x00AC,0x00AD,0x00AE,0x0407,
        0x00B0,0x00B1,0x0406,0x0456,0x0491,0x00B5,0x00B6,0x00B7,0x0451,0x2116,0x0454,0x00BB,0x0458,0x0405,0x0455,0x0457,
        0x0410,0x0411,0x0412,0x0413,0x0414,0x0415,0x0416,0x0417,0x0418,0x0419,0x041A,0x041B,0x041C,0x041D,0x041E,0x041F,
        0x0420,0x0421,0x0422,0x0423,0x0424,0x0425,0x0426,0x0427,0x0428,0x0429,0x042A,0x042B,0x042C,0x042D,0x042E,0x042F,
        0x0430,0x0431,0x0432,0x0433,0x0434,0x0435,0x0436,0x0437,0x0438,0x0439,0x043A,0x043B,0x043C,0x043D,0x043E,0x043F,
        0x0440,0x0441,0x0442,0x0443,0x0444,0x0445,0x0446,0x0447,0x0448,0x0449,0x044A,0x044B,0x044C,0x044D,0x044E,0x044F
    ]
}
