import Foundation
import Testing
@testable import FarCore

/// Checks the public viewer/editor contracts against the same original text;
/// expected ranges are written in source coordinates, not folded coordinates.
struct TextSearchConsistencyTests {
    @Test func fuzzyViewerAndEditorSelectTheSameOriginalUnicodeInBothEncodings() throws {
        let cases: [(String, String, String)] = [
            ("🙂 café!", "cafe", "café"),
            ("x cafe\u{301}!", "cafe", "cafe\u{301}"),
            ("🙂 Straße!", "strasse", "Straße"),
            ("x æther!", "aether", "æther"),
            ("x ℌ𝔢𝔩𝔩𝔬!", "hello", "ℌ𝔢𝔩𝔩𝔬"),
            ("x ①２٣!", "123", "①２٣")
        ]
        for (text, pattern, original) in cases {
            let expected = (text as NSString).range(of: original, options: .literal)
            let query = EditorSearchQuery(pattern: pattern, fuzzy: true)
            #expect(try EditorEditing.find(in: text, query: query, from: 0) == expected)
            #expect(try EditorEditing.find(in: text, query: query, from: text.utf16.count, direction: .backward) == expected)
            for encoding in [ViewerEncoding.utf8, .utf16LE] {
                let data = try #require(text.data(using: encoding == .utf8 ? .utf8 : .utf16LittleEndian))
                let document = try ViewerDocument(source: TextSearchMemorySource(data), encoding: encoding)
                let start = encoding == .utf8 ? (text as NSString).substring(to: expected.location).utf8.count : expected.location * 2
                let end = encoding == .utf8 ? (text as NSString).substring(to: NSMaxRange(expected)).utf8.count : NSMaxRange(expected) * 2
                let viewerQuery = ViewerSearchQuery(pattern: pattern, fuzzy: true)
                #expect(try ViewerSearch.find(document: document, query: viewerQuery, from: 0)?.byteRange == Int64(start)..<Int64(end))
                #expect(try ViewerSearch.find(document: document, query: viewerQuery, from: document.size, direction: .backward)?.byteRange == Int64(start)..<Int64(end))
            }
        }
    }

    @Test func expandedScalarIsReplacedOnlyOnceAndTrailingAccentIsNotOrphaned() throws {
        let repeated = EditorSearchQuery(pattern: "s", fuzzy: true)
        #expect(try EditorEditing.find(in: "ßß", query: repeated, from: 1) == NSRange(location: 1, length: 1))
        let edit = try EditorEditing.replaceAll(in: "ßß", query: repeated, replacement: "X")
        #expect(edit.text == "XX" && edit.count == 2)
        let accents = try EditorEditing.replaceAll(in: "cafe\u{301} café", query: .init(pattern: "cafe", fuzzy: true), replacement: "tea")
        #expect(accents.text == "tea tea" && accents.count == 2)
    }

    @Test func wholeWordsAndCaseRemainIndependentOfFoldingAcrossViewerPages() throws {
        let text = String(repeating: " ", count: 65_533) + "cafeteria CAFÉ cafe\u{301}!"
        let expected = (text as NSString).range(of: "cafe\u{301}", options: .literal)
        let query = EditorSearchQuery(pattern: "cafe", caseSensitive: true, wholeWords: true, fuzzy: true)
        #expect(try EditorEditing.find(in: text, query: query, from: 0) == expected)
        let data = Data(text.utf8)
        let document = try ViewerDocument(source: TextSearchMemorySource(data), encoding: .utf8)
        let bytes = Int64((text as NSString).substring(to: expected.location).utf8.count)..<Int64((text as NSString).substring(to: NSMaxRange(expected)).utf8.count)
        let viewerQuery = ViewerSearchQuery(pattern: "cafe", caseSensitive: true, wholeWords: true, fuzzy: true)
        #expect(try ViewerSearch.find(document: document, query: viewerQuery, from: 0)?.byteRange == bytes)
        #expect(try ViewerSearch.find(document: document, query: viewerQuery, from: document.size, wrap: true)?.byteRange == bytes)
    }

    @Test func emptyNormalizedPatternAndUnsupportedRegexCombinationFailExplicitly() {
        #expect(throws: (any Error).self) { try EditorEditing.validate(.init(pattern: "\u{301}", fuzzy: true)) }
        #expect(throws: (any Error).self) { try ViewerSearch.validate(.init(pattern: "\u{301}", fuzzy: true)) }
        #expect(throws: (any Error).self) { try EditorEditing.validate(.init(pattern: "x", regex: true, fuzzy: true)) }
        #expect(throws: (any Error).self) { try ViewerSearch.validate(.init(pattern: "x", mode: .regex, fuzzy: true)) }
    }
}

private final class TextSearchMemorySource: ViewerByteSource, @unchecked Sendable {
    let data: Data
    let identity = UUID().uuidString
    var size: Int64 { Int64(data.count) }
    init(_ data: Data) { self.data = data }
    func read(offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset <= size, count >= 0 else { throw ViewerError.invalidRange }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count))
    }
    func verifyUnchanged() throws {}
}
