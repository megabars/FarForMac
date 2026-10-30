import Foundation
import Darwin

public enum EditorLineEnding: String, CaseIterable, Codable, Sendable {
    case preserve, lf, crlf
    public var title: String {
        switch self {
        case .preserve: return "Сохранить исходные"
        case .lf: return "LF"
        case .crlf: return "CRLF"
        }
    }
}

public struct EditorFormat: Codable, Equatable, Sendable {
    public var encoding: ViewerEncoding
    public var bom: Bool
    public var lineEnding: EditorLineEnding
    public init(encoding: ViewerEncoding = .utf8, bom: Bool = false, lineEnding: EditorLineEnding = .preserve) {
        self.encoding = encoding; self.bom = bom; self.lineEnding = lineEnding
    }
}

public struct EditorSnapshot: Sendable {
    public let url: URL
    public let originalURL: URL
    public let identity: String
    public let data: Data
    public let text: String
    public let format: EditorFormat
}

public enum EditorError: Error, LocalizedError, Equatable {
    case changed, destinationExists, tooLarge, invalidEncoding, unrepresentable, invalidFormat
    case notRegularFile, unsupportedURL, io(String)
    public var errorDescription: String? {
        switch self {
        case .changed: return "Файл изменён, удалён или ссылка перенаправлена. Перечитайте его или сохраните копию."
        case .destinationExists: return "Файл назначения уже существует. Выберите другой путь или подтвердите замену текущего файла."
        case .tooLarge: return "Редактор поддерживает файлы до 8 МиБ."
        case .invalidEncoding: return "Файл нельзя без потерь прочитать в выбранной кодировке."
        case .unrepresentable: return "Текст нельзя без потерь сохранить в выбранной кодировке."
        case .invalidFormat: return "Выберите конкретную кодировку. BOM доступен только для Unicode."
        case .notRegularFile: return "Редактирование доступно только для обычных файлов."
        case .unsupportedURL: return "Поддерживаются только локальные файлы."
        case .io(let message): return message
        }
    }
}

/// Bounded, lossless editor storage. A replacement is coordinated and rechecked
/// immediately before rename. Non-cooperating writers can still race that final
/// check and rename; no filesystem API offers compare-and-swap by file identity.
public enum EditorDocument {
    public static let maximumSize = 8 * 1_024 * 1_024

    public static func load(url: URL, encoding: ViewerEncoding = .automatic) throws -> EditorSnapshot {
        do {
            let source = try LocalViewerSource(url: url)
            guard source.size <= maximumSize else { throw EditorError.tooLarge }
            var data = Data(), offset: Int64 = 0
            while offset < source.size {
                let chunk = try source.read(offset: offset, count: Int(min(Int64(LocalViewerSource.maximumReadCount), source.size - offset)))
                data.append(chunk); offset += Int64(chunk.count)
            }
            let document = try ViewerDocument(source: EditorMemorySource(data), encoding: encoding)
            let text = try strictText(document)
            let format = EditorFormat(encoding: document.encoding, bom: document.bomLength > 0)
            // This also guards against code-page aliases or decoder behavior
            // that cannot reproduce the original bytes exactly.
            guard try encode(text: text, format: format) == data else { throw EditorError.invalidEncoding }
            try source.verifyUnchanged()
            return EditorSnapshot(url: source.url, originalURL: url.standardizedFileURL,
                                  identity: source.identity, data: data, text: text, format: format)
        } catch let error as ViewerError {
            throw translate(error)
        }
    }

    public static func encode(text: String, format: EditorFormat) throws -> Data {
        try validate(format)
        let normalized = normalizedText(text, lineEnding: format.lineEnding)
        guard normalized.utf8.count <= maximumSize * 4 else { throw EditorError.tooLarge }
        var data = Data(bomBytes(format))
        switch format.encoding {
        case .utf8: data.append(contentsOf: normalized.utf8)
        case .utf16LE, .utf16BE:
            for unit in normalized.utf16 {
                let low = UInt8(truncatingIfNeeded: unit), high = UInt8(truncatingIfNeeded: unit >> 8)
                data.append(contentsOf: format.encoding == .utf16LE ? [low, high] : [high, low])
                guard data.count <= maximumSize else { throw EditorError.tooLarge }
            }
        case .windows1251, .windows1252, .latin1:
            let map = format.encoding == .windows1251 ? cp1251 : (format.encoding == .windows1252 ? cp1252 : latin1)
            for scalar in normalized.unicodeScalars {
                guard let byte = map[scalar.value] else { throw EditorError.unrepresentable }
                data.append(byte)
                guard data.count <= maximumSize else { throw EditorError.tooLarge }
            }
        case .automatic: throw EditorError.invalidFormat
        }
        guard data.count <= maximumSize else { throw EditorError.tooLarge }
        return data
    }

    /// A nil expected snapshot always means exclusive creation. Replacing any
    /// existing destination requires a concrete snapshot captured by the caller.
    public static func save(text: String, format: EditorFormat, to url: URL,
                            expected: EditorSnapshot? = nil, allowOverwrite: Bool = false) throws -> EditorSnapshot {
        guard url.isFileURL else { throw EditorError.unsupportedURL }
        let data = try encode(text: text, format: format)
        let original = url.standardizedFileURL
        let resolved = expected == nil ? original : original.resolvingSymlinksInPath()
        if let expected {
            guard original == expected.originalURL || original == expected.url,
                  resolved == expected.url else { throw EditorError.changed }
        }
        // Creating alongside the destination guarantees the final rename stays
        // on one filesystem. O_EXCL and a private mode protect the staging file.
        let stage = resolved.deletingLastPathComponent().appendingPathComponent(".far-editor-" + UUID().uuidString)
        let fd = open(stage.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ioError() }
        defer { close(fd); _ = unlink(stage.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw ioError() }
                offset += result
            }
        }
        var coordinationError: NSError?, operationError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: resolved, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                guard coordinatedURL.standardizedFileURL == resolved else { throw EditorError.changed }
                if let expected {
                    try verify(expected, at: original)
                    // copyfile preserves permissions, ACLs and extended attributes.
                    // No source data is copied over the staged edited bytes.
                    guard copyfile(resolved.path, stage.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC)) == 0 else { throw ioError() }
                    guard fsync(fd) == 0 else { throw ioError() }
                    try verify(expected, at: original)
                    guard rename(stage.path, resolved.path) == 0 else { throw ioError() }
                } else {
                    guard fsync(fd) == 0 else { throw ioError() }
                    guard renamex_np(stage.path, original.path, UInt32(RENAME_EXCL)) == 0 else {
                        if errno == EEXIST { throw EditorError.destinationExists }
                        throw ioError()
                    }
                }
                // Best-effort directory flush after the file itself is durable.
                let directory = open(resolved.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
                if directory >= 0 { _ = fsync(directory); close(directory) }
            } catch { operationError = error }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw EditorError.io(coordinationError.localizedDescription) }
        let saved = try load(url: original, encoding: format.encoding)
        guard saved.data == data else { throw EditorError.changed }
        return saved
    }

    public static func utf16Offset(forByteOffset offset: Int64, in snapshot: EditorSnapshot) -> Int {
        var bytes = Int64(bomBytes(snapshot.format).count), units = 0
        for scalar in snapshot.text.unicodeScalars {
            let width = byteWidth(scalar, encoding: snapshot.format.encoding)
            if offset < bytes + Int64(width) { return units }
            bytes += Int64(width); units += scalar.utf16.count
        }
        return units
    }

    public static func byteOffset(forUTF16Offset offset: Int, text: String, format: EditorFormat) throws -> Int64 {
        try validate(format)
        // Snap an interior UTF-16 surrogate position to the scalar's beginning.
        var units = 0, prefix = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard units + scalar.utf16.count <= max(0, offset) else { break }
            prefix.append(scalar); units += scalar.utf16.count
        }
        return Int64(try encode(text: String(prefix), format: format).count)
    }

    private static func verify(_ expected: EditorSnapshot, at original: URL) throws {
        do {
            guard original.resolvingSymlinksInPath() == expected.url else { throw EditorError.changed }
            let current = try load(url: original, encoding: expected.format.encoding)
            guard current.identity == expected.identity, current.data == expected.data else { throw EditorError.changed }
        } catch { throw EditorError.changed }
    }

    private static func strictText(_ document: ViewerDocument) throws -> String {
        var text = "", offset: Int64 = 0
        while offset < document.size {
            let page = try document.page(at: offset)
            guard !page.invalidSequences else { throw EditorError.invalidEncoding }
            text += page.text
            guard page.endOffset > offset else { throw EditorError.invalidEncoding }
            offset = page.endOffset
        }
        return text
    }

    private static func normalizedText(_ text: String, lineEnding: EditorLineEnding) -> String {
        guard lineEnding != .preserve else { return text }
        let lf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return lineEnding == .lf ? lf : lf.replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func validate(_ format: EditorFormat) throws {
        guard format.encoding != .automatic else { throw EditorError.invalidFormat }
        if format.bom, ![ViewerEncoding.utf8, .utf16LE, .utf16BE].contains(format.encoding) { throw EditorError.invalidFormat }
    }
    private static func bomBytes(_ format: EditorFormat) -> [UInt8] {
        guard format.bom else { return [] }
        switch format.encoding {
        case .utf8: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        default: return []
        }
    }
    private static func byteWidth(_ scalar: Unicode.Scalar, encoding: ViewerEncoding) -> Int {
        switch encoding {
        case .utf8, .automatic: return scalar.utf8.count
        case .utf16LE, .utf16BE: return scalar.utf16.count * 2
        default: return 1
        }
    }
    // Derive inverse tables from the viewer's shared, stable decoder so opening
    // and saving a legacy code page cannot disagree about a byte's meaning.
    private static func codePage(_ encoding: ViewerEncoding) -> [UInt32: UInt8] {
        let document = try! ViewerDocument(source: EditorMemorySource(Data((0...255).map(UInt8.init))), encoding: encoding)
        var map: [UInt32: UInt8] = [:]
        for byte in 0...255 {
            let page = try! document.page(at: Int64(byte), byteCount: 1)
            if !page.invalidSequences, let scalar = page.text.unicodeScalars.first { map[scalar.value] = UInt8(byte) }
        }
        return map
    }
    private static let cp1251 = codePage(.windows1251)
    private static let cp1252 = codePage(.windows1252)
    private static let latin1 = codePage(.latin1)
    private static func ioError() -> EditorError { .io(String(cString: strerror(errno))) }
    private static func translate(_ error: ViewerError) -> EditorError {
        switch error {
        case .changedFile: return .changed
        case .unsupportedURL: return .unsupportedURL
        case .notRegularFile: return .notRegularFile
        default: return .io(error.localizedDescription)
        }
    }
}

private struct EditorMemorySource: ViewerByteSource {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    var size: Int64 { Int64(bytes.count) }
    var identity: String { "editor-memory" }
    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset <= size, count >= 0, count <= LocalViewerSource.maximumReadCount else { throw ViewerError.invalidRange }
        return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + count))
    }
    func verifyUnchanged() throws {}
}
