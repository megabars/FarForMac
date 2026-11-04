import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
struct FileDescriptionsTests {
    @Test func quotedUnicodeAndContinuationRecordsPreserveUntouchedBytes() throws {
        let tree = try DescriptionTree()
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("\"отчёт 🙂.txt\"   Первая строка\r\n\tВторая строка\r\n\r\nuntouched\t  keep spacing  \nlast old".utf8)
        try original.write(to: tree.file)
        var snapshot = try FileDescriptions.load(directory: tree.root)
        #expect(snapshot.description(for: "отчёт 🙂.txt") == "Первая строка\nВторая строка")
        _ = try snapshot.save()
        #expect(try Data(contentsOf: tree.file) == original)
        try snapshot.setDescription("new", for: "last")
        let saved = try snapshot.save()
        let expected = Data([0xEF, 0xBB, 0xBF]) + Data("\"отчёт 🙂.txt\"   Первая строка\r\n\tВторая строка\r\n\r\nuntouched\t  keep spacing  \nlast new".utf8)
        #expect(try Data(contentsOf: tree.file) == expected)
        #expect(saved.description(for: "last") == "new")
    }

    @Test func createAppendEditAndDeleteRecordsRoundTrip() throws {
        let tree = try DescriptionTree()
        var snapshot = try FileDescriptions.load(directory: tree.root)
        #expect(snapshot.descriptions.isEmpty)
        _ = try snapshot.save()
        #expect(!FileManager.default.fileExists(atPath: tree.file.path))
        try snapshot.setDescription("Описание 🙂\nВторая строка", for: "new file.txt")
        snapshot = try snapshot.save()
        #expect(try String(contentsOf: tree.file, encoding: .utf8) == "\"new file.txt\" Описание 🙂\r\n Вторая строка\r\n")
        try snapshot.setDescription("Other", for: "other")
        snapshot = try snapshot.save()
        #expect(try String(contentsOf: tree.file, encoding: .utf8) == "\"new file.txt\" Описание 🙂\r\n Вторая строка\r\nother Other\r\n")
        try snapshot.setDescription("", for: "new file.txt")
        snapshot = try snapshot.save()
        #expect(snapshot.descriptions == ["other": "Other"])
        #expect(try String(contentsOf: tree.file, encoding: .utf8) == "other Other\r\n")
    }

    @Test func appendAfterMissingFinalNewlineInsertsOneSeparator() throws {
        let tree = try DescriptionTree()
        try Data("one old".utf8).write(to: tree.file)
        var snapshot = try FileDescriptions.load(directory: tree.root)
        try snapshot.setDescription("next", for: "two")
        _ = try snapshot.save()
        #expect(try String(contentsOf: tree.file, encoding: .utf8) == "one old\r\ntwo next\r\n")
    }

    @Test func equalDescriptionDoesNotRewriteWhitespaceOrIdentity() throws {
        let tree = try DescriptionTree()
        let data = Data("a\t value   \r\n".utf8)
        try data.write(to: tree.file)
        var snapshot = try FileDescriptions.load(directory: tree.root)
        let inode = try FileManager.default.attributesOfItem(atPath: tree.file.path)[.systemFileNumber] as? NSNumber
        try snapshot.setDescription("value", for: "a")
        _ = try snapshot.save()
        #expect(try Data(contentsOf: tree.file) == data)
        #expect(try FileManager.default.attributesOfItem(atPath: tree.file.path)[.systemFileNumber] as? NSNumber == inode)
    }

    @Test func staleSnapshotRefusesModifiedDeletedAndNewlyCreatedDestinations() throws {
        for scenario in 0..<3 {
            let tree = try DescriptionTree()
            if scenario != 2 { try Data("a first\n".utf8).write(to: tree.file) }
            var snapshot = try FileDescriptions.load(directory: tree.root)
            try snapshot.setDescription("ours", for: "a")
            if scenario == 1 { try FileManager.default.removeItem(at: tree.file) }
            else { try Data("a theirs\n".utf8).write(to: tree.file) }
            #expect(throws: FileDescriptionError.changed) { try snapshot.save() }
            if scenario != 1 { #expect(try String(contentsOf: tree.file, encoding: .utf8) == "a theirs\n") }
        }
    }

    @Test func replacingSameBytesStillConflicts() throws {
        let tree = try DescriptionTree()
        let data = Data("a first\n".utf8)
        try data.write(to: tree.file)
        var snapshot = try FileDescriptions.load(directory: tree.root)
        try snapshot.setDescription("ours", for: "a")
        let replacement = tree.root.appendingPathComponent("replacement")
        try data.write(to: replacement)
        #expect(rename(replacement.path, tree.file.path) == 0)
        #expect(throws: FileDescriptionError.changed) { try snapshot.save() }
        #expect(try Data(contentsOf: tree.file) == data)
    }

    @Test func unsafeTargetsAreRejectedWithoutOpeningFIFOOrFollowingLink() throws {
        for kind in 0..<3 {
            let tree = try DescriptionTree()
            switch kind {
            case 0:
                let target = tree.root.appendingPathComponent("target")
                try Data("a untouched".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: tree.file, withDestinationURL: target)
            case 1: #expect(mkfifo(tree.file.path, 0o600) == 0)
            default: try FileManager.default.createDirectory(at: tree.file, withIntermediateDirectories: false)
            }
            #expect(throws: FileDescriptionError.notRegularFile) { try FileDescriptions.load(directory: tree.root) }
        }
    }

    @Test func symlinkIntroducedBeforeSavingDoesNotModifyItsTarget() throws {
        let tree = try DescriptionTree()
        var snapshot = try FileDescriptions.load(directory: tree.root)
        try snapshot.setDescription("ours", for: "a")
        let target = tree.root.appendingPathComponent("target")
        let original = Data("a theirs".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: tree.file, withDestinationURL: target)
        #expect(throws: FileDescriptionError.notRegularFile) { try snapshot.save() }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test func malformedAndLegacyFilesAreRefusedWithoutLoss() throws {
        let tree = try DescriptionTree()
        let cases = [Data([0xFF, 0xFE, 0x61]), Data("\"unclosed description\n".utf8), Data("a one\na two\n".utf8), Data(" orphan\n".utf8), Data("\"a\"junk\n".utf8), Data("../path no\n".utf8), Data("a zero\0byte\n".utf8)]
        for data in cases {
            try data.write(to: tree.file)
            #expect(throws: (any Error).self) { try FileDescriptions.load(directory: tree.root) }
            #expect(try Data(contentsOf: tree.file) == data)
        }
    }

    @Test func invalidEditsCannotChangeSnapshotOrDisk() throws {
        let tree = try DescriptionTree()
        var snapshot = try FileDescriptions.load(directory: tree.root)
        for name in ["", ".", "..", "../x", "a/b", "a\"b", "a\nb", "a\tb"] {
            #expect(throws: FileDescriptionError.invalidName) { try snapshot.setDescription("value", for: name) }
        }
        for value in ["zero\0byte", "a\n\nb", String(repeating: "a", count: 65_537)] {
            #expect(throws: FileDescriptionError.invalidDescription) { try snapshot.setDescription(value, for: "a") }
        }
        #expect(snapshot.descriptions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tree.file.path))
    }

    @Test func byteAndLineLimitsAreEnforced() throws {
        let tree = try DescriptionTree()
        try Data(repeating: 65, count: FileDescriptions.maximumSize + 1).write(to: tree.file)
        #expect(throws: FileDescriptionError.tooLarge) { try FileDescriptions.load(directory: tree.root) }
        try Data(String(repeating: "\n", count: FileDescriptions.maximumLines + 1).utf8).write(to: tree.file)
        #expect(throws: FileDescriptionError.tooLarge) { try FileDescriptions.load(directory: tree.root) }
    }

    @Test func atomicReplacementPreservesPermissions() throws {
        let tree = try DescriptionTree()
        try Data("a old\n".utf8).write(to: tree.file)
        #expect(chmod(tree.file.path, 0o640) == 0)
        var snapshot = try FileDescriptions.load(directory: tree.root)
        try snapshot.setDescription("new", for: "a")
        _ = try snapshot.save()
        let permissions = try FileManager.default.attributesOfItem(atPath: tree.file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o640)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.root.path) == ["descript.ion"])
    }
}

private final class DescriptionTree {
    let root: URL
    var file: URL { root.appendingPathComponent("descript.ion") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FarDescriptionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite
struct FileDescriptionPropagationTests {
    @Test func explicitLegacyEncodingPreservesUntouchedBytesAndRefusesLoss() throws {
        for encoding in [FileDescriptionEncoding.windows1251, .dos866] {
            let tree = try DescriptionTree()
            let data = try #require("old Старое\r\nuntouched\t  Байты  \n".data(using: encoding.stringEncoding))
            try data.write(to: tree.file)
            #expect(throws: FileDescriptionError.invalidEncoding) { try FileDescriptions.load(directory: tree.root) }
            var snapshot = try FileDescriptions.load(directory: tree.root, encoding: encoding)
            #expect(snapshot.description(for: "old") == "Старое")
            try snapshot.setDescription("Новое", for: "old")
            snapshot = try snapshot.save()
            #expect(try Data(contentsOf: tree.file) == "old Новое\r\nuntouched\t  Байты  \n".data(using: encoding.stringEncoding))
            let saved = try Data(contentsOf: tree.file)
            try snapshot.setDescription("🙂", for: "old")
            #expect(throws: FileDescriptionError.unrepresentableEncoding) { try snapshot.save() }
            #expect(try Data(contentsOf: tree.file) == saved)
        }
    }

    @Test func copyThenMoveSameDirectoryPreservesUnrelatedRecords() throws {
        let tree = try DescriptionTree()
        try Data("old first\nkeep\t  exact bytes  \r\n".utf8).write(to: tree.file)
        var transfer = try #require(try FileDescriptionTransfer.prepare(source: tree.root.appendingPathComponent("old"), destination: tree.root.appendingPathComponent("new")))
        try transfer.publishDescription()
        #expect(try FileDescriptions.load(directory: tree.root).descriptions == ["old": "first", "new": "first", "keep": "exact bytes"])
        try transfer.removeSourceDescription()
        #expect(try FileDescriptions.load(directory: tree.root).descriptions == ["new": "first", "keep": "exact bytes"])
        #expect(try String(contentsOf: tree.file, encoding: .utf8).contains("keep\t  exact bytes  \r\n"))
    }

    @Test func renameUsesOriginalMapAndCompletedSubsetOnly() throws {
        let tree = try DescriptionTree()
        try Data("one first\ntwo second\nkeep untouched\n".utf8).write(to: tree.file)
        let plan = try FileDescriptionRenamePlan.prepare(directory: tree.root)
        try plan.apply(completedRenames: [(source: "one", destination: "new")])
        #expect(try FileDescriptions.load(directory: tree.root).descriptions == ["new": "first", "two": "second", "keep": "untouched"])
        let swapped = try FileDescriptionRenamePlan.prepare(directory: tree.root)
        try swapped.apply(completedRenames: [(source: "new", destination: "two"), (source: "two", destination: "new")])
        #expect(try FileDescriptions.load(directory: tree.root).descriptions == ["new": "second", "two": "first", "keep": "untouched"])
    }

    @Test func stalePropagationAndRenameNeverClobberConcurrentEdits() throws {
        let source = try DescriptionTree(), target = try DescriptionTree()
        try Data("one first\n".utf8).write(to: source.file)
        var transfer = try #require(try FileDescriptionTransfer.prepare(source: source.root.appendingPathComponent("one"), destination: target.root.appendingPathComponent("one")))
        try Data("concurrent keep\n".utf8).write(to: target.file)
        #expect(throws: FileDescriptionError.changed) { try transfer.publishDescription() }
        #expect(try FileDescriptions.load(directory: source.root).description(for: "one") == "first")
        #expect(try String(contentsOf: target.file, encoding: .utf8) == "concurrent keep\n")
        let rename = try FileDescriptionRenamePlan.prepare(directory: source.root)
        try Data("one external\n".utf8).write(to: source.file)
        #expect(throws: FileDescriptionError.changed) { try rename.apply(completedRenames: [(source: "one", destination: "new")]) }
        #expect(try String(contentsOf: source.file, encoding: .utf8) == "one external\n")
    }
}
