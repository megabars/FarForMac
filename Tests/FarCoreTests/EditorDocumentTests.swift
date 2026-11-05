import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
struct EditorDocumentTests {
    @Test
    func everySupportedEncodingRoundTripsWithMixedLineEndings() throws {
        let tree = try EditorTemporaryTree()
        for encoding in ViewerEncoding.allCases where encoding != .automatic {
            let text: String
            switch encoding {
            case .windows1251: text = "Привет Ёё\r\na\nb\rc\r\n"
            case .windows1252: text = "€ “café”\r\na\nb\rc\r\n"
            case .latin1: text = "café\u{80}\r\na\nb\rc\r\n"
            case .dos437: text = "café ╔═╗\r\na\nb\rc\r\n"
            case .dos866: text = "Привет Ёё ╔═╗\r\na\nb\rc\r\n"
            default: text = "🙂Жcafé\r\na\nb\rc\r\n"
            }
            let unicode = [ViewerEncoding.utf8, .utf16LE, .utf16BE].contains(encoding)
            for bom in unicode ? [false, true] : [false] {
                let format = EditorFormat(encoding: encoding, bom: bom)
                let data = try EditorDocument.encode(text: text, format: format)
                let url = tree.root.appendingPathComponent(UUID().uuidString)
                try data.write(to: url)
                let snapshot = try EditorDocument.load(url: url, encoding: encoding)
                #expect(snapshot.text == text)
                #expect(snapshot.format == format)
                #expect(snapshot.data == data)
                let saved = try EditorDocument.save(text: text, format: snapshot.format, to: url, expected: snapshot)
                #expect(saved.data == data)
                #expect(saved.text == text)
            }
        }
    }

    @Test
    func everyDefinedSingleByteCodePageValueIsReversible() throws {
        let tree = try EditorTemporaryTree()
        for encoding in [ViewerEncoding.windows1251, .windows1252, .latin1, .dos437, .dos866] {
            let undefined: Set<Int> = encoding == .windows1251 ? [0x98] : (encoding == .windows1252 ? [0x81, 0x8D, 0x8F, 0x90, 0x9D] : [])
            let original = Data((0...255).filter { !undefined.contains($0) }.map(UInt8.init))
            let url = tree.root.appendingPathComponent(encoding.rawValue)
            try original.write(to: url)
            let snapshot = try EditorDocument.load(url: url, encoding: encoding)
            #expect(try EditorDocument.encode(text: snapshot.text, format: snapshot.format) == original)
        }
    }

    @Test
    func malformedInputAndLossyOutputAreRefused() throws {
        let tree = try EditorTemporaryTree()
        let cases: [(ViewerEncoding, Data)] = [
            (.utf8, Data([0x61, 0xC0, 0xAF])),
            (.utf8, Data([0xEF, 0xBB, 0xBF, 0xED, 0xA0, 0x80])),
            (.utf16LE, Data([0x00, 0xD8])),
            (.utf16BE, Data([0x00])),
            (.windows1251, Data([0x98])),
            (.windows1252, Data([0x81]))
        ]
        for (encoding, data) in cases {
            let url = tree.root.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            #expect(throws: EditorError.invalidEncoding) { try EditorDocument.load(url: url, encoding: encoding) }
            #expect(try Data(contentsOf: url) == data)
        }
        for encoding in [ViewerEncoding.windows1251, .windows1252, .latin1, .dos437, .dos866] {
            #expect(throws: EditorError.unrepresentable) {
                try EditorDocument.encode(text: "🙂", format: EditorFormat(encoding: encoding))
            }
        }
        #expect(throws: EditorError.invalidFormat) { try EditorDocument.encode(text: "a", format: EditorFormat(encoding: .automatic)) }
        #expect(throws: EditorError.invalidFormat) { try EditorDocument.encode(text: "a", format: EditorFormat(encoding: .latin1, bom: true)) }
    }

    @Test
    func emptyAndBOMOnlyFilesRemainLossless() throws {
        let tree = try EditorTemporaryTree()
        for encoding in [ViewerEncoding.utf8, .utf16LE, .utf16BE] {
            for bom in [false, true] {
                let format = EditorFormat(encoding: encoding, bom: bom)
                let data = try EditorDocument.encode(text: "", format: format)
                let url = tree.root.appendingPathComponent(UUID().uuidString)
                try data.write(to: url)
                let snapshot = try EditorDocument.load(url: url, encoding: encoding)
                #expect(snapshot.text.isEmpty)
                #expect(snapshot.format == format)
                #expect(snapshot.data == data)
            }
        }
    }

    @Test
    func automaticDetectsUnicodeAndRefusesUndefinedLegacyBytes() throws {
        let tree = try EditorTemporaryTree()
        for encoding in [ViewerEncoding.utf8, .utf16LE, .utf16BE] {
            let url = tree.root.appendingPathComponent(encoding.rawValue)
            try EditorDocument.encode(text: "Hello🙂", format: EditorFormat(encoding: encoding, bom: true)).write(to: url)
            #expect(try EditorDocument.load(url: url).format.encoding == encoding)
        }
        let invalid = tree.root.appendingPathComponent("invalid")
        try Data([0x81]).write(to: invalid)
        #expect(throws: EditorError.invalidEncoding) { try EditorDocument.load(url: invalid) }
    }

    @Test
    func lineEndingConversionRequiresExplicitChoiceAndReturnsSavedText() throws {
        let tree = try EditorTemporaryTree()
        let original = "one\r\ntwo\nthree\rfour\n"
        for lineEnding in [EditorLineEnding.preserve, .lf, .crlf, .cr] {
            let url = tree.root.appendingPathComponent(lineEnding.rawValue)
            try Data(original.utf8).write(to: url)
            let snapshot = try EditorDocument.load(url: url)
            let format = EditorFormat(encoding: .utf8, bom: true, lineEnding: lineEnding)
            let saved = try EditorDocument.save(text: original, format: format, to: url, expected: snapshot)
            let expected = lineEnding == .preserve ? original : (lineEnding == .lf ? "one\ntwo\nthree\nfour\n" : (lineEnding == .cr ? "one\rtwo\rthree\rfour\r" : "one\r\ntwo\r\nthree\r\nfour\r\n"))
            #expect(saved.text == expected)
            #expect(saved.data == Data([0xEF, 0xBB, 0xBF]) + Data(expected.utf8))
        }
    }

    @Test
    func cursorMappingSnapsInsideScalarsAndPreservesBOMOffsets() throws {
        let tree = try EditorTemporaryTree()
        let text = "a🙂Жz"
        for encoding in [ViewerEncoding.utf8, .utf16LE, .utf16BE] {
            let format = EditorFormat(encoding: encoding, bom: true)
            let url = tree.root.appendingPathComponent(encoding.rawValue)
            try EditorDocument.encode(text: text, format: format).write(to: url)
            let snapshot = try EditorDocument.load(url: url)
            let bom = encoding == .utf8 ? 3 : 2
            let aWidth = encoding == .utf8 ? 1 : 2
            #expect(EditorDocument.utf16Offset(forByteOffset: 0, in: snapshot) == 0)
            #expect(try EditorDocument.byteOffset(forUTF16Offset: 0, text: text, format: format) == Int64(bom))
            #expect(try EditorDocument.byteOffset(forUTF16Offset: 2, text: text, format: format) == Int64(bom + aWidth))
            for index in 0..<4 {
                #expect(EditorDocument.utf16Offset(forByteOffset: Int64(bom + aWidth + index), in: snapshot) == 1)
            }
            for index in [0, 1, 3, 4, 5] {
                let offset = try EditorDocument.byteOffset(forUTF16Offset: index, text: text, format: format)
                #expect(EditorDocument.utf16Offset(forByteOffset: offset, in: snapshot) == index)
            }
            #expect(EditorDocument.utf16Offset(forByteOffset: Int64.max, in: snapshot) == text.utf16.count)
        }
    }

    @Test
    func changedReplacedMissingAndRetargetedSourcesRefuseSave() throws {
        let tree = try EditorTemporaryTree()
        let url = tree.root.appendingPathComponent("source")
        try Data("original".utf8).write(to: url)
        let first = try EditorDocument.load(url: url)
        try Data("external".utf8).write(to: url)
        #expect(throws: EditorError.changed) { try EditorDocument.save(text: "edited", format: first.format, to: url, expected: first) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "external")
        let second = try EditorDocument.load(url: url)
        try Data("external".utf8).write(to: url, options: .atomic)
        #expect(throws: EditorError.changed) { try EditorDocument.save(text: "edited", format: second.format, to: url, expected: second) }
        let third = try EditorDocument.load(url: url)
        try FileManager.default.removeItem(at: url)
        #expect(throws: EditorError.changed) { try EditorDocument.save(text: "edited", format: third.format, to: url, expected: third) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try Data("original".utf8).write(to: url)
        let other = tree.root.appendingPathComponent("other")
        try Data("other".utf8).write(to: other)
        let link = tree.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let linked = try EditorDocument.load(url: link)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(throws: EditorError.changed) { try EditorDocument.save(text: "edited", format: linked.format, to: link, expected: linked) }
        #expect(try String(contentsOf: other, encoding: .utf8) == "other")
        #expect(try String(contentsOf: url, encoding: .utf8) == "original")
    }

    @Test
    func saveAsIsExclusiveEvenWithAllowOverwriteAndSymlinks() throws {
        let tree = try EditorTemporaryTree()
        let url = tree.root.appendingPathComponent("saved")
        let saved = try EditorDocument.save(text: "new", format: EditorFormat(), to: url)
        #expect(saved.text == "new")
        #expect(throws: EditorError.destinationExists) { try EditorDocument.save(text: "other", format: EditorFormat(), to: url, allowOverwrite: true) }
        let link = tree.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: EditorError.destinationExists) { try EditorDocument.save(text: "other", format: EditorFormat(), to: link) }
        let dangling = tree.root.appendingPathComponent("dangling")
        let absent = tree.root.appendingPathComponent("absent")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: absent)
        #expect(throws: EditorError.destinationExists) { try EditorDocument.save(text: "other", format: EditorFormat(), to: dangling) }
        #expect(!FileManager.default.fileExists(atPath: absent.path))
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
        let replacement = try EditorDocument.save(text: "approved", format: EditorFormat(), to: url, expected: saved, allowOverwrite: true)
        #expect(replacement.text == "approved")
    }

    @Test
    func savingThroughSymlinkPreservesLinkPermissionsAndExtendedAttributes() throws {
        let tree = try EditorTemporaryTree()
        let file = tree.root.appendingPathComponent("file")
        try Data("before".utf8).write(to: file)
        #expect(chmod(file.path, 0o640) == 0)
        let attribute = Data("attribute-value".utf8)
        let setResult = attribute.withUnsafeBytes { setxattr(file.path, "com.far.editor-test", $0.baseAddress, attribute.count, 0, 0) }
        #expect(setResult == 0)
        let link = tree.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let snapshot = try EditorDocument.load(url: link)
        let saved = try EditorDocument.save(text: "after", format: snapshot.format, to: link, expected: snapshot)
        #expect(saved.originalURL == link)
        #expect(saved.url == file)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == file.path)
        var info = stat()
        #expect(stat(file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o640)
        var restored = Data(count: attribute.count)
        let length = restored.withUnsafeMutableBytes { getxattr(file.path, "com.far.editor-test", $0.baseAddress, attribute.count, 0, 0) }
        #expect(length == attribute.count)
        #expect(restored == attribute)
        let children = try FileManager.default.contentsOfDirectory(atPath: tree.root.path)
        #expect(!children.contains { $0.hasPrefix(".far-editor-") })
    }

    @Test
    func sizeLimitAndSpecialFilesDoNotAllocateOrBlock() throws {
        let tree = try EditorTemporaryTree()
        let sparse = tree.root.appendingPathComponent("large")
        let fd = open(sparse.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(ftruncate(fd, off_t(EditorDocument.maximumSize + 1)) == 0)
        #expect(throws: EditorError.tooLarge) { try EditorDocument.load(url: sparse) }
        #expect(throws: EditorError.tooLarge) {
            try EditorDocument.encode(text: String(repeating: "a", count: EditorDocument.maximumSize + 1), format: EditorFormat())
        }
        let fifo = tree.root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: EditorError.notRegularFile) { try EditorDocument.load(url: fifo) }
        #expect(throws: EditorError.notRegularFile) { try EditorDocument.load(url: tree.root) }
    }
}

final class EditorTemporaryTree {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FarEditorTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}
