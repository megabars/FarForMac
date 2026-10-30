import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
struct EditorRecoveryTests {
    @Test
    func recoverySurvivesStoreRecreationWithoutWritingTheSource() throws {
        let tree = try EditorTemporaryTree()
        let source = tree.root.appendingPathComponent("source")
        try Data("saved bytes".utf8).write(to: source)
        let directory = tree.root.appendingPathComponent("recovery")
        let record = EditorRecoveryRecord(sourceURL: source, text: "несохранённый 🙂\r\ntext",
                                          format: EditorFormat(encoding: .windows1251), selection: 4,
                                          baseIdentity: "device:inode:version")
        try EditorRecoveryStore(directory: directory).save(record)
        let records = try EditorRecoveryStore(directory: directory).loadAll()
        #expect(records.count == 1)
        #expect(records.first?.id == record.id)
        #expect(records.first?.sourceURL == source)
        #expect(records.first?.text == record.text)
        #expect(records.first?.format == record.format)
        #expect(records.first?.selection == 4)
        #expect(records.first?.baseIdentity == record.baseIdentity)
        #expect(try String(contentsOf: source, encoding: .utf8) == "saved bytes")
        var info = stat()
        #expect(stat(directory.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        let file = directory.appendingPathComponent(record.id.uuidString + ".json")
        #expect(stat(file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test
    func updatesSameRecordAtomicallyAndDeletesOnlyChosenRecovery() throws {
        let tree = try EditorTemporaryTree()
        let store = EditorRecoveryStore(directory: tree.root.appendingPathComponent("recovery"))
        #expect(try store.loadAll().isEmpty)
        var record = EditorRecoveryRecord(text: "first")
        try store.save(record)
        record.text = "updated"
        try store.save(record)
        let second = EditorRecoveryRecord(text: "second", modified: Date().addingTimeInterval(1))
        try store.save(second)
        let records = try store.loadAll()
        #expect(records.map(\.id) == [second.id, record.id])
        #expect(records.last?.text == "updated")
        try store.remove(id: record.id)
        try store.remove(id: record.id)
        #expect(try store.loadAll().map(\.id) == [second.id])
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(!names.contains { $0.hasPrefix(".recovery-") })
    }

    @Test
    func corruptOversizeAndMismatchedRecordsAreReportedAndRetained() throws {
        let tree = try EditorTemporaryTree()
        let directory = tree.root.appendingPathComponent("recovery")
        let store = EditorRecoveryStore(directory: directory)
        let good = EditorRecoveryRecord(text: "good")
        try store.save(good)
        let bad = directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{invalid".utf8).write(to: bad)
        #expect(chmod(bad.path, 0o600) == 0)
        #expect(throws: EditorRecoveryError.invalidRecord(bad)) { try store.loadAll() }
        let available = try store.loadAvailable()
        #expect(available.records.map(\.id) == [good.id])
        #expect(available.warnings.count == 1)
        #expect(available.warnings.first?.contains(bad.path) == true)
        #expect(try Data(contentsOf: bad) == Data("{invalid".utf8))
        try FileManager.default.removeItem(at: bad)
        let mismatched = directory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(EditorRecoveryRecord(text: "wrong id")).write(to: mismatched)
        #expect(chmod(mismatched.path, 0o600) == 0)
        #expect(throws: EditorRecoveryError.invalidRecord(mismatched)) { try store.loadAll() }
        try FileManager.default.removeItem(at: mismatched)
        let huge = directory.appendingPathComponent(UUID().uuidString + ".json")
        let fd = open(huge.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(ftruncate(fd, off_t(EditorRecoveryStore.maximumRecordSize + 1)) == 0)
        #expect(throws: EditorRecoveryError.invalidRecord(huge)) { try store.loadAll() }
        #expect(FileManager.default.fileExists(atPath: huge.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(good.id.uuidString + ".json").path))
    }

    @Test
    func recoveryRejectsSymlinkRecordsAndInvalidSelections() throws {
        let tree = try EditorTemporaryTree()
        let directory = tree.root.appendingPathComponent("recovery")
        let store = EditorRecoveryStore(directory: directory)
        let good = EditorRecoveryRecord(text: "good")
        try store.save(good)
        let source = tree.root.appendingPathComponent("source")
        try Data("keep source".utf8).write(to: source)
        let link = directory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: EditorRecoveryError.invalidRecord(link)) { try store.loadAll() }
        #expect(try String(contentsOf: source, encoding: .utf8) == "keep source")
        let badSelection = EditorRecoveryRecord(text: "text", selection: 100)
        #expect(throws: EditorRecoveryError.invalidRecord(directory.appendingPathComponent(badSelection.id.uuidString + ".json"))) {
            try store.save(badSelection)
        }
        let automatic = EditorRecoveryRecord(text: "text", format: EditorFormat(encoding: .automatic))
        #expect(throws: EditorRecoveryError.invalidRecord(directory.appendingPathComponent(automatic.id.uuidString + ".json"))) {
            try store.save(automatic)
        }
    }

    @Test
    func recoveryDirectoryCannotBeASymlink() throws {
        let tree = try EditorTemporaryTree()
        let link = tree.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tree.root)
        let store = EditorRecoveryStore(directory: link)
        #expect(throws: EditorRecoveryError.invalidDirectory) { try store.save(EditorRecoveryRecord(text: "buffer")) }
    }

    @Test
    func recoveryBoundsRecordCountAndKeepsSkippedFiles() throws {
        let tree = try EditorTemporaryTree()
        let directory = tree.root.appendingPathComponent("recovery")
        let store = EditorRecoveryStore(directory: directory)
        try store.save(EditorRecoveryRecord(text: "first"))
        for _ in 0..<EditorRecoveryStore.maximumLoadCount {
            let record = EditorRecoveryRecord(text: "draft")
            let url = directory.appendingPathComponent(record.id.uuidString + ".json")
            try JSONEncoder().encode(record).write(to: url)
            #expect(chmod(url.path, 0o600) == 0)
        }
        let result = try store.loadAvailable()
        #expect(result.records.count == EditorRecoveryStore.maximumLoadCount)
        #expect(result.warnings == [EditorRecoveryError.loadLimit.localizedDescription])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == EditorRecoveryStore.maximumLoadCount + 1)
        #expect(throws: EditorRecoveryError.loadLimit) { try store.loadAll() }
    }

    @Test
    func recoveryBoundsTotalBytesIncludingMalformedRecords() throws {
        let tree = try EditorTemporaryTree()
        let directory = tree.root.appendingPathComponent("recovery")
        let store = EditorRecoveryStore(directory: directory)
        let good = EditorRecoveryRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, text: "healthy")
        try store.save(good)
        for value in ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"] {
            let url = directory.appendingPathComponent(value + ".json")
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            #expect(fd >= 0)
            #expect(ftruncate(fd, off_t(EditorRecoveryStore.maximumLoadSize / 2 + 1)) == 0)
            close(fd)
        }
        let result = try store.loadAvailable()
        #expect(result.records.map(\.id) == [good.id])
        #expect(result.warnings.count == 2)
        #expect(result.warnings.contains(EditorRecoveryError.loadLimit.localizedDescription))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
    }
}
