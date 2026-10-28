import Foundation
import Testing
@testable import FarCore

@Suite
struct FileSortTests {
    @Test
    func groupingAndDirectionAreIndependent() {
        let entries = [entry("a"), entry("z-folder", directory: true), entry("b")]
        #expect(FileService.sorted(entries, options: .init()).map(\.name) == ["z-folder", "a", "b"])
        #expect(FileService.sorted(entries, options: .init(ascending: false)).map(\.name) == ["z-folder", "b", "a"])
        #expect(FileService.sorted(entries, options: .init(directoriesFirst: false)).map(\.name) == ["a", "b", "z-folder"])
    }

    @Test
    func naturalAndCaseOptionsChangeOrdering() {
        let numbered = [entry("file10"), entry("file2")]
        #expect(FileService.sorted(numbered, options: .init()).map(\.name) == ["file2", "file10"])
        #expect(FileService.sorted(numbered, options: .init(naturalOrder: false)).map(\.name) == ["file10", "file2"])
        let mixedCase = [entry("a"), entry("B")]
        #expect(FileService.sorted(mixedCase, options: .init(naturalOrder: false)).map(\.name) == ["a", "B"])
        #expect(FileService.sorted(mixedCase, options: .init(caseSensitive: true, naturalOrder: false)).map(\.name) == ["B", "a"])
    }

    @Test
    func extensionAndDatesUseNameForTiesAndHandleMissingValues() {
        let entries = [entry("z.swift", created: 200, accessed: 100), entry("a.swift", created: 100, accessed: 200), entry("b.md")]
        #expect(FileService.sorted(entries, options: .init(sort: .extension)).map(\.name) == ["b.md", "a.swift", "z.swift"])
        #expect(FileService.sorted(Array(entries.reversed()), options: .init(sort: .extension)).map(\.name) == ["b.md", "a.swift", "z.swift"])
        #expect(FileService.sorted(entries, options: .init(sort: .created)).map(\.name) == ["b.md", "a.swift", "z.swift"])
        #expect(FileService.sorted(entries, options: .init(sort: .accessed, ascending: false)).map(\.name) == ["a.swift", "z.swift", "b.md"])
        let mixedExtensions = [entry("z.TXT"), entry("a.txt")]
        #expect(FileService.sorted(mixedExtensions, options: .init(sort: .extension)).map(\.name) == ["a.txt", "z.TXT"])
        #expect(FileService.sorted(mixedExtensions, options: .init(sort: .extension, caseSensitive: true, naturalOrder: false)).map(\.name) == ["z.TXT", "a.txt"])
    }

    @Test
    func selectedSortUsesMarksWithinOptionalDirectoryGroups() {
        let entries = [entry("a"), entry("b"), entry("z-folder", directory: true)]
        let marked: Set<String> = [entries[1].id]
        #expect(FileService.sorted(entries, options: .init(sort: .selected), markedIDs: marked).map(\.name) == ["z-folder", "b", "a"])
        #expect(FileService.sorted(entries, options: .init(sort: .selected, directoriesFirst: false), markedIDs: marked).map(\.name) == ["b", "a", "z-folder"])
        #expect(FileService.sorted(entries, options: .init(sort: .selected, ascending: false, directoriesFirst: false), markedIDs: marked).map(\.name) == ["z-folder", "a", "b"])
    }

    @Test
    func sortOptionsRoundTripAllSettings() throws {
        for sort in FileSort.allCases {
            let options = FileSortOptions(sort: sort, ascending: false, directoriesFirst: false, caseSensitive: true, naturalOrder: false)
            #expect(try JSONDecoder().decode(FileSortOptions.self, from: JSONEncoder().encode(options)) == options)
        }
        let defaultEntry = entry("file")
        #expect(defaultEntry.created == nil)
        #expect(defaultEntry.accessed == nil)
        #expect(defaultEntry.permissions.isEmpty)
        #expect(defaultEntry.owner.isEmpty)
    }

    private func entry(_ name: String, directory: Bool = false, created: TimeInterval? = nil, accessed: TimeInterval? = nil) -> FileEntry {
        FileEntry(
            url: URL(fileURLWithPath: "/test/" + name), name: name,
            isDirectory: directory, isSymbolicLink: false, size: 0, modified: nil,
            created: created.map(Date.init(timeIntervalSince1970:)),
            accessed: accessed.map(Date.init(timeIntervalSince1970:))
        )
    }
}
