import Foundation
import Darwin
import CArchive

/// Configure exactly one native filter. Automatic bidding could otherwise decode
/// an unvalidated nested XZ before the caller can reject the filter chain.
enum ArchiveCompression {
    static func prepare(_ archive: OpaquePointer, fd: Int32, size: Int64,
                        cancellation: TransferCancellation) throws {
        let prefix = try read(fd, offset: 0, count: Int(min(6, size)), size: size)
        let filter: Int32
        if prefix.starts(with: [0x1f, 0x8b]) { filter = ARCHIVE_FILTER_GZIP }
        else if prefix.starts(with: [0x42, 0x5a, 0x68]) { filter = ARCHIVE_FILTER_BZIP2 }
        else if prefix == [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0] {
            try validateXZ(fd, size: size, cancellation: cancellation)
            filter = ARCHIVE_FILTER_XZ
        } else { filter = ARCHIVE_FILTER_NONE }
        let status: Int32
        switch filter {
        case ARCHIVE_FILTER_GZIP: status = archive_read_support_filter_gzip(archive)
        case ARCHIVE_FILTER_BZIP2: status = archive_read_support_filter_bzip2(archive)
        case ARCHIVE_FILTER_XZ: status = archive_read_support_filter_xz(archive)
        default: status = archive_read_support_filter_none(archive)
        }
        // Registration may offer an external-process fallback with ARCHIVE_WARN.
        // Refuse it before append_filter initializes the decoder.
        guard status == ARCHIVE_OK, archive_read_append_filter(archive, filter) == ARCHIVE_OK else {
            throw ArchiveError.unsupportedFormat
        }
    }

    private static func read(_ fd: Int32, offset: Int64, count: Int, size: Int64) throws -> [UInt8] {
        guard offset >= 0, count >= 0, Int64(count) <= size, offset <= size - Int64(count) else {
            throw ArchiveError.corruptArchive("Неполная структура сжатого архива.")
        }
        var result = [UInt8](repeating: 0, count: count)
        guard pread(fd, &result, count, off_t(offset)) == count else { throw ArchiveError.io("Не удалось прочитать сжатый архив.") }
        return result
    }
    private static func u32(_ data: [UInt8], _ index: Int) -> UInt32 {
        UInt32(data[index]) | UInt32(data[index + 1]) << 8 | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
    }
    private static func crc32(_ data: ArraySlice<UInt8>) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb8_8320) }
        }
        return ~crc
    }
    private static func vli(_ data: [UInt8], cursor: inout Int, end: Int) throws -> Int64 {
        var result: UInt64 = 0
        for index in 0..<9 {
            guard cursor < end else { throw ArchiveError.corruptArchive("Неполное целое XZ.") }
            let byte = data[cursor]; cursor += 1
            guard index == 0 || byte != 0 else { throw ArchiveError.corruptArchive("Неканоническое целое XZ.") }
            result |= UInt64(byte & 0x7f) << (index * 7)
            if byte & 0x80 == 0 { return Int64(result) }
        }
        throw ArchiveError.corruptArchive("Переполнение целого XZ.")
    }

    /// XZ v1.2.1 §§2–5: one stream, one LZMA2 block, dictionary <=64 MiB.
    /// Check framing before invoking libarchive, whose XZ memory limit is unlimited.
    /// LZMA2 chunk boundaries are scanned without decoding their payloads, so a
    /// forged Index cannot conceal a second, unchecked block dictionary.
    private static func validateXZ(_ fd: Int32, size: Int64, cancellation: TransferCancellation) throws {
        guard size >= 32, size % 4 == 0 else { throw ArchiveError.corruptArchive("Неполный поток XZ.") }
        var end = size
        while end > 0 {
            if cancellation.isCancelled { throw ArchiveError.cancelled }
            let amount = Int(min(65536, end))
            let tail = try read(fd, offset: end - Int64(amount), count: amount, size: size)
            if let nonzero = tail.lastIndex(where: { $0 != 0 }) { end -= Int64(amount - nonzero - 1); break }
            end -= Int64(amount)
        }
        guard end >= 32, (size - end) % 4 == 0 else { throw ArchiveError.corruptArchive("Неверное заполнение XZ.") }
        let header = try read(fd, offset: 0, count: 12, size: size)
        let footer = try read(fd, offset: end - 12, count: 12, size: size)
        guard footer[10] == 0x59, footer[11] == 0x5a,
              header[6] == 0, header[7] & 0xf0 == 0,
              header[6] == footer[8], header[7] == footer[9],
              crc32(header[6..<8]) == u32(header, 8), crc32(footer[4..<10]) == u32(footer, 0) else {
            throw ArchiveError.corruptArchive("Неверный заголовок или окончание XZ.")
        }
        let checkBytes: Int64
        switch header[7] {
        case 0: checkBytes = 0
        case 1: checkBytes = 4
        case 4: checkBytes = 8
        case 10: checkBytes = 32
        default: throw ArchiveError.unsupportedFormat
        }
        let indexSize = (Int64(u32(footer, 4)) + 1) * 4
        guard indexSize >= 8, indexSize <= 64, indexSize <= end - 24 else { throw ArchiveError.unsupportedFormat }
        let indexStart = end - 12 - indexSize
        let index = try read(fd, offset: indexStart, count: Int(indexSize), size: size)
        guard index[0] == 0, crc32(index[0..<(index.count - 4)]) == u32(index, index.count - 4) else {
            throw ArchiveError.corruptArchive("Неверный индекс XZ.")
        }
        var cursor = 1
        guard try vli(index, cursor: &cursor, end: index.count - 4) == 1 else { throw ArchiveError.unsupportedFormat }
        let unpadded = try vli(index, cursor: &cursor, end: index.count - 4)
        let uncompressed = try vli(index, cursor: &cursor, end: index.count - 4)
        guard index[(cursor)..<(index.count - 4)].count <= 3,
              index[cursor..<(index.count - 4)].allSatisfy({ $0 == 0 }),
              unpadded > 0, unpadded <= indexStart - 12,
              (unpadded + 3) / 4 * 4 == indexStart - 12 else { throw ArchiveError.unsupportedFormat }
        guard uncompressed <= 2 * 1024 * 1024 * 1024 else { throw ArchiveError.limitExceeded("размер потока TAR.XZ") }
        let start = try read(fd, offset: 12, count: 2, size: size)
        let blockHeaderSize = (Int(start[0]) + 1) * 4
        guard start[0] > 0, blockHeaderSize >= 8, Int64(blockHeaderSize) + checkBytes < unpadded,
              start[1] & 0x3f == 0 else { throw ArchiveError.unsupportedFormat }
        let block = try read(fd, offset: 12, count: blockHeaderSize, size: size)
        guard crc32(block[0..<(block.count - 4)]) == u32(block, block.count - 4) else { throw ArchiveError.corruptArchive("Неверный заголовок блока XZ.") }
        cursor = 2
        let compressedBytes = unpadded - Int64(blockHeaderSize) - checkBytes
        if start[1] & 0x40 != 0 {
            guard try vli(block, cursor: &cursor, end: block.count - 4) == compressedBytes else { throw ArchiveError.corruptArchive("Размер блока XZ.") }
        }
        if start[1] & 0x80 != 0 {
            guard try vli(block, cursor: &cursor, end: block.count - 4) == uncompressed else { throw ArchiveError.corruptArchive("Размер блока XZ.") }
        }
        guard try vli(block, cursor: &cursor, end: block.count - 4) == 0x21,
              try vli(block, cursor: &cursor, end: block.count - 4) == 1,
              cursor < block.count - 4 else { throw ArchiveError.unsupportedFormat }
        let property = block[cursor]; cursor += 1
        guard property <= 40 else { throw ArchiveError.unsupportedFormat }
        let dictionary = property == 40 ? UInt64(UInt32.max) : UInt64(2 | (property & 1)) << (Int(property / 2) + 11)
        guard dictionary <= 64 * 1024 * 1024 else { throw ArchiveError.limitExceeded("словарь XZ больше 64 МиБ") }
        guard block[cursor..<(block.count - 4)].allSatisfy({ $0 == 0 }) else { throw ArchiveError.corruptArchive("Заполнение заголовка XZ.") }
        var position = Int64(12 + blockHeaderSize), output: Int64 = 0
        let compressedEnd = position + compressedBytes
        var ended = false
        while position < compressedEnd {
            if cancellation.isCancelled { throw ArchiveError.cancelled }
            let control = try read(fd, offset: position, count: 1, size: size)[0]
            position += 1
            if control == 0 { ended = true; break }
            guard control <= 2 || control >= 0x80 else { throw ArchiveError.corruptArchive("Неверный блок LZMA2.") }
            let count = control >= 0x80 ? 4 : 2
            guard Int64(count) <= compressedEnd - position else { throw ArchiveError.corruptArchive("Неполный блок LZMA2.") }
            let chunk = try read(fd, offset: position, count: count, size: size)
            let packed = Int64(chunk[count - 2]) << 8 | Int64(chunk[count - 1])
            let unpacked = control >= 0x80 ? (Int64(control & 0x1f) << 16 | Int64(chunk[0]) << 8 | Int64(chunk[1])) + 1 : packed + 1
            let properties: Int64 = control >= 0xc0 ? 1 : 0
            position += Int64(count) + properties
            guard packed + 1 <= compressedEnd - position, unpacked <= uncompressed - output else { throw ArchiveError.corruptArchive("Размер блока LZMA2.") }
            position += packed + 1; output += unpacked
        }
        guard ended, position == compressedEnd, output == uncompressed else { throw ArchiveError.corruptArchive("Границы блока LZMA2.") }
    }
}
