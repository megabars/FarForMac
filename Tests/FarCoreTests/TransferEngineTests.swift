import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
final class TransferEngineTests {
    let root: URL
    let fm = FileManager.default
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TransferEngineTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? fm.removeItem(at: root) }
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func file(_ path: String, _ text: String = "data") throws -> URL {
        let url = root.appendingPathComponent(path)
        try Data(text.utf8).write(to: url)
        return url
    }
    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func run(_ sources: [URL], _ target: URL, move: Bool = false,
             cancellation: TransferCancellation = TransferCancellation(),
             progress: @escaping (TransferProgress) -> Void = { _ in },
             conflict: @escaping (TransferConflict) -> TransferDecision = { _ in .skip },
             error: @escaping (TransferFailure) -> TransferErrorDecision = { _ in .skip }) -> TransferResult {
        TransferEngine.run(TransferRequest(sources: sources, destination: target, move: move), cancellation: cancellation,
                           onProgress: progress, onConflict: conflict, onError: error)
    }
    func staging(_ directory: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".farmac-transfer-") }
    }

    @Test func newNameAndMetadataArePreserved() throws {
        let source = try file("source", "content")
        let destination = root.appendingPathComponent("new-name")
        let date = Date(timeIntervalSince1970: 123456789)
        let value = Array("attribute".utf8)
        #expect(value.withUnsafeBytes { setxattr(source.path, "com.farmac.test", $0.baseAddress, $0.count, 0, 0) } == 0)
        // Resource fork is the extended attribute macOS uses for named resource data.
        let forkValue = Array("resource".utf8)
        #expect(forkValue.withUnsafeBytes { setxattr(source.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) } == 0)
        try fm.setAttributes([.posixPermissions: 0o640, .modificationDate: date], ofItemAtPath: source.path)
        let result = run([source], destination)
        #expect(result.completed == 1 && result.failed == 0 && !result.cancelled)
        #expect(try text(destination) == "content")
        let attributes = try fm.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(attributes[.modificationDate] as? Date == date)
        var copied = [UInt8](repeating: 0, count: 64)
        let count = getxattr(destination.path, "com.farmac.test", &copied, copied.count, 0, 0)
        #expect(Array(copied.prefix(max(0, count))) == value)
        let forkCount = getxattr(destination.path, "com.apple.ResourceFork", &copied, copied.count, 0, 0)
        #expect(Array(copied.prefix(max(0, forkCount))) == forkValue)
        #expect(try staging(root).isEmpty)
    }

    @Test func replacementIsInvisibleUntilExplicitDecisionAndFullCopy() throws {
        let source = try file("source", "new content")
        let target = try file("target", "old content")
        var conflicts = 0
        let result = run([source], target, progress: { update in
            if update.phase == "Копирование" { #expect((try? self.text(target)) == "old content") }
        }, conflict: { value in
            conflicts += 1
            #expect(value.source == source && !value.isDirectoryMerge)
            #expect((try? self.text(target)) == "old content")
            return .replace
        })
        #expect(result.completed == 1 && result.failed == 0 && conflicts == 1)
        #expect(try text(target) == "new content")
        #expect(try text(source) == "new content")
        #expect(try staging(root).isEmpty)
    }

    @Test func midBatchConflictRetainsAccuratePartialResult() throws {
        let first = try file("first", "one")
        let second = try file("second", "two")
        let target = try directory("target")
        let collision = try file("target/second", "keep")
        let result = run([first, second], target, move: true)
        #expect(result.completed == 1 && result.skipped == 1 && result.failed == 0)
        #expect(!result.summary.contains("Операция завершена."))
        #expect(!fm.fileExists(atPath: first.path))
        #expect(fm.fileExists(atPath: second.path))
        #expect(try text(collision) == "keep")
    }

    @Test func cancellationInChunkPreservesMoveSourceAndExistingDestination() throws {
        let source = root.appendingPathComponent("large")
        try Data(repeating: 42, count: 4 * 1024 * 1024).write(to: source)
        let target = try file("target", "old")
        let token = TransferCancellation()
        let result = run([source], target, move: true, cancellation: token, progress: { update in
            if update.fileBytes >= 1024 * 1024 { token.cancel() }
        }, conflict: { _ in .replace })
        #expect(result.cancelled && result.completed == 0)
        #expect(try Data(contentsOf: source).count == 4 * 1024 * 1024)
        #expect(try text(target) == "old")
        #expect(try staging(root).isEmpty)
    }

    @Test func cancellationAfterEarlierPublicationKeepsCompletedWork() throws {
        let first = try file("first")
        let second = try file("second")
        let target = try directory("target")
        let token = TransferCancellation()
        let result = run([first, second], target, move: true, cancellation: token, progress: { update in
            if update.currentPath == second.path && update.phase == "Копирование" { token.cancel() }
        })
        #expect(result.cancelled && result.completed == 1)
        #expect(!fm.fileExists(atPath: first.path))
        #expect(fm.fileExists(atPath: second.path))
        #expect(try text(target.appendingPathComponent("first")) == "data")
        #expect(!fm.fileExists(atPath: target.appendingPathComponent("second").path))
        #expect(try staging(target).isEmpty)
    }

    @Test func symlinkCycleAndDanglingLinkAreCopiedWithoutFollowing() throws {
        let source = try directory("source")
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("cycle").path, withDestinationPath: ".")
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("dangling").path, withDestinationPath: "absent")
        let destination = root.appendingPathComponent("copy")
        let result = run([source], destination, move: true)
        #expect(result.completed == 2 && result.failed == 0)
        #expect(!fm.fileExists(atPath: source.path))
        #expect(try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("cycle").path) == ".")
        #expect(try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("dangling").path) == "absent")
    }

    @Test func directoryMergeRequiresSeparateDecisionAndKeepsUnrelatedChildren() throws {
        let source = try directory("source")
        _ = try file("source/new", "new")
        _ = try file("source/same", "new same")
        let target = try directory("target/source")
        _ = try file("target/source/keep", "keep")
        let same = try file("target/source/same", "old same")
        var conflicts = 0
        let result = run([source], target.deletingLastPathComponent(), move: true, conflict: { value in
            conflicts += 1
            return value.isDirectoryMerge ? .merge : .skip
        })
        #expect(result.completed == 1 && result.skipped == 1 && result.failed == 0 && conflicts == 2)
        #expect(try text(target.appendingPathComponent("keep")) == "keep")
        #expect(try text(same) == "old same")
        #expect(try text(source.appendingPathComponent("same")) == "new same")
        #expect(!fm.fileExists(atPath: source.appendingPathComponent("new").path))
    }

    @Test func successfulMergeMoveRemovesOnlyEmptySourceContainer() throws {
        let source = try directory("source")
        _ = try file("source/new", "new")
        let target = try directory("target/source")
        _ = try file("target/source/existing", "keep")
        let result = run([source], target.deletingLastPathComponent(), move: true, conflict: { _ in .merge })
        #expect(result.completed == 1 && result.failed == 0)
        #expect(!fm.fileExists(atPath: source.path))
        #expect(try text(target.appendingPathComponent("new")) == "new")
        #expect(try text(target.appendingPathComponent("existing")) == "keep")
    }

    @Test func sourceChangesDiscardStagingAndRetryFromFreshSnapshot() throws {
        let source = try file("source", "initial")
        let destination = root.appendingPathComponent("copy")
        var changed = false, errors = 0
        let result = run([source], destination, progress: { update in
            if update.phase == "Копирование" && update.fileBytes > 0 && !changed {
                changed = true
                try? Data("updated".utf8).write(to: source)
            }
        }, error: { problem in
            errors += 1
            #expect(problem.message.contains("изменил"))
            #expect(!self.fm.fileExists(atPath: destination.path))
            return .retry
        })
        #expect(errors == 1 && result.completed == 1 && result.failed == 0)
        #expect(try text(destination) == "updated")
        #expect(try staging(root).isEmpty)
    }

    @Test func sourceChangesWithSkipPreserveOriginalAndContinueNextItem() throws {
        let first = try file("first", "first")
        let second = try file("second", "second")
        let target = try directory("target")
        var changed = false
        let result = run([first, second], target, move: true, progress: { update in
            if update.currentPath == first.path && update.fileBytes > 0 && !changed {
                changed = true; try? Data("changed".utf8).write(to: first)
            }
        })
        #expect(result.failed == 1 && result.completed == 1 && !result.issues.isEmpty)
        #expect(try text(first) == "changed")
        #expect(!fm.fileExists(atPath: target.appendingPathComponent("first").path))
        #expect(!fm.fileExists(atPath: second.path))
        #expect(try staging(target).isEmpty)
    }

    @Test func changedDestinationNeedsNewDecisionBeforeOverwrite() throws {
        let source = try file("source", "new")
        let destination = try file("target", "old")
        var decisions = 0, errors = 0
        let result = run([source], destination, conflict: { _ in
            decisions += 1
            if decisions == 1 { try? Data("other writer".utf8).write(to: destination); return .replace }
            return .skip
        }, error: { _ in errors += 1; return .retry })
        #expect(decisions == 2 && errors == 1 && result.skipped == 1 && result.completed == 0)
        #expect(try text(destination) == "other writer")
        #expect(try staging(root).isEmpty)
    }

    @Test func renamedConflictTargetIsValidatedAgain() throws {
        let source = try file("source", "new")
        let destination = try file("target", "old")
        let result = run([source], destination, conflict: { _ in .rename("renamed") })
        #expect(result.completed == 1)
        #expect(try text(destination) == "old")
        #expect(try text(root.appendingPathComponent("renamed")) == "new")
        let invalid = run([source], destination, conflict: { _ in .rename("../outside") })
        #expect(invalid.failed == 1)
    }

    @Test func hardlinkSelfCopyNestedSelectionsAndDescendantAliasAreRejected() throws {
        let source = try directory("source")
        let file = try file("source/file")
        let hardlink = root.appendingPathComponent("hardlink")
        try fm.linkItem(at: file, to: hardlink)
        let nested = try directory("source/nested")
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: nested)
        #expect(run([file], hardlink).failed == 1)
        #expect(run([source], alias).failed == 1)
        #expect(run([source, file], root).failed == 2)
        #expect(try text(file) == "data")
        #expect(try fm.contentsOfDirectory(atPath: nested.path).isEmpty)
    }

    @Test func missingSourceAndMultipleSourcesWithNewFilenameFailBeforeMutation() throws {
        let first = try file("first")
        let second = try file("second")
        let target = try directory("target")
        let missing = root.appendingPathComponent("missing")
        #expect(run([first, missing], target, move: true).failed == 2)
        #expect(run([first, second], root.appendingPathComponent("new-name"), move: true).failed == 2)
        #expect(fm.fileExists(atPath: first.path) && fm.fileExists(atPath: second.path))
        #expect(try fm.contentsOfDirectory(atPath: target.path).isEmpty)
    }
    @Test func queuedSourceReplacementRequiresExplicitRetry() throws {
        let source = try file("source", "old")
        let destination = root.appendingPathComponent("copy")
        let request = TransferRequest(sources: [source], destination: destination, move: true)
        try fm.removeItem(at: source)
        _ = try file("source", "replacement")
        var errors = 0
        let rejected = TransferEngine.run(request, cancellation: TransferCancellation(), onProgress: { _ in },
                                          onConflict: { _ in .skip }, onError: { problem in
            errors += 1
            #expect(problem.message.contains("очередь"))
            return .skip
        })
        #expect(rejected.failed == 1 && errors == 1)
        #expect(try text(source) == "replacement")
        #expect(!fm.fileExists(atPath: destination.path))
        let accepted = TransferEngine.run(request, cancellation: TransferCancellation(), onProgress: { _ in },
                                          onConflict: { _ in .skip }, onError: { _ in .retry })
        #expect(accepted.completed == 1 && accepted.failed == 0)
        #expect(try text(destination) == "replacement")
    }

    @Test func moveRetainsNewChildrenAndCleanupRetryDoesNotRecopy() throws {
        let source = try directory("source")
        _ = try file("source/planned", "copied")
        let destination = root.appendingPathComponent("copy")
        var added = false, retries = 0
        let result = run([source], destination, move: true, progress: { update in
            if update.phase == "Удаление источника" && update.currentPath == source.path && !added {
                added = true
                _ = try? self.file("source/arrived-later", "keep")
            }
        }, error: { problem in
            retries += 1
            #expect(problem.message.contains("не полностью"))
            #expect((try? self.text(destination.appendingPathComponent("planned"))) == "copied")
            return retries == 1 ? .retry : .skip
        })
        #expect(result.completed == 1 && result.failed == 1 && retries == 2)
        #expect(try text(source.appendingPathComponent("arrived-later")) == "keep")
        #expect(!fm.fileExists(atPath: source.appendingPathComponent("planned").path))
        #expect(try text(destination.appendingPathComponent("planned")) == "copied")
        #expect(!fm.fileExists(atPath: destination.appendingPathComponent("arrived-later").path))
    }

    @Test func cancellationAfterPublicationReportsRetainedSource() throws {
        let source = try file("source")
        let destination = root.appendingPathComponent("copy")
        let token = TransferCancellation()
        let result = run([source], destination, move: true, cancellation: token, progress: { update in
            if update.phase == "Удаление источника" { token.cancel() }
        })
        #expect(result.cancelled && result.completed == 1)
        #expect(result.issues.contains { $0.contains("оставшиеся объекты сохранены") })
        #expect(try text(destination) == "data")
        #expect(try text(source) == "data")
    }

    @Test func directoryCopyReportsAggregateBytesAcrossChildren() throws {
        let source = try directory("source")
        _ = try file("source/one", "12345")
        _ = try file("source/two", "1234567")
        let destination = root.appendingPathComponent("copy")
        var values: [Int64] = []
        var last: TransferProgress?
        let result = run([source], destination, progress: { update in
            if update.phase == "Копирование" { values.append(update.completedBytes) }
            last = update
        })
        #expect(result.completed == 2 && result.failed == 0)
        #expect(values == values.sorted())
        #expect(last?.completedBytes == 12 && last?.totalBytes == 12)
        #expect(last?.completedItems == 2 && last?.totalItems == 2)
    }

    @Test func readOnlyStagingDirectoryCanBeCleanedAfterCancellation() throws {
        let source = try directory("source")
        let first = try directory("source/a")
        _ = try file("source/a/file", "data")
        _ = try file("source/z", "data")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: first.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: first.path) }
        let token = TransferCancellation()
        var triggered = false
        let result = run([source], root.appendingPathComponent("copy"), cancellation: token, progress: { update in
            if update.phase == "Копирование" && URL(fileURLWithPath: update.currentPath).lastPathComponent == "z" {
                triggered = true; token.cancel()
            }
        })
        #expect(triggered)
        #expect(result.cancelled && result.completed == 0, "\(result.summary) \(result.issues)")
        #expect(try staging(root).isEmpty)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("copy").path))
    }

    @Test func movePreservesOriginalWhenPublishedCopyDisappears() throws {
        for replacement in [false, true] {
            let source = try file("source-\(replacement)", "original")
            let destination = root.appendingPathComponent("copy-\(replacement)")
            var changed = false
            let result = run([source], destination, move: true, progress: { update in
                if update.phase == "Удаление источника" && !changed {
                    changed = true
                    try? self.fm.removeItem(at: destination)
                    if replacement { try? Data("unrelated".utf8).write(to: destination) }
                }
            })
            #expect(result.failed == 1 && result.completed == 1)
            #expect(result.issues.contains { $0.contains("копия отсутствует или изменилась") })
            #expect(try text(source) == "original")
            if replacement { #expect(try text(destination) == "unrelated") }
            else { #expect(!fm.fileExists(atPath: destination.path)) }
        }
    }

    @Test func insufficientSpacePreflightUsesSparseFileWithoutAllocatingDisk() throws {
        let source = try file("sparse", "")
        let target = try directory("target")
        let available = try #require((fm.attributesOfFileSystem(forPath: target.path)[.systemFreeSize] as? NSNumber)?.int64Value)
        let handle = open(source.path, O_WRONLY)
        #expect(handle >= 0)
        defer { close(handle) }
        #expect(ftruncate(handle, available + 1024 * 1024) == 0)
        var message = ""
        let result = run([source], target, error: { problem in message = problem.message; return .skip })
        #expect(result.failed == 1 && result.completed == 0)
        #expect(message.contains("Недостаточно свободного места"))
        #expect(try fm.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func deniedDestinationWriteAccessFailsBeforeCopy() throws {
        guard geteuid() != 0 else { return }
        let source = try file("source")
        let target = try directory("target")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        let result = run([source], target, move: true)
        #expect(result.failed == 1 && result.completed == 0)
        #expect(fm.fileExists(atPath: source.path))
        #expect(try fm.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func hardlinkedSourcesAreMovedAsIndependentCopies() throws {
        let source = try directory("source")
        let first = try file("source/first", "shared")
        let second = source.appendingPathComponent("second")
        try fm.linkItem(at: first, to: second)
        let target = root.appendingPathComponent("copy")
        let result = run([source], target, move: true)
        #expect(result.completed == 2 && result.failed == 0, "\(result.issues)")
        #expect(!fm.fileExists(atPath: source.path))
        let a = target.appendingPathComponent("first"), b = target.appendingPathComponent("second")
        let aAttributes = try fm.attributesOfItem(atPath: a.path), bAttributes = try fm.attributesOfItem(atPath: b.path)
        #expect((aAttributes[.systemFileNumber] as? NSNumber) != (bAttributes[.systemFileNumber] as? NSNumber))
        try Data("edited".utf8).write(to: a)
        #expect(try text(b) == "shared")
    }

    @Test func mergeRejectsChangedSourceDirectoryAndReportsPartialAfterPublication() throws {
        let source = try directory("source")
        let planned = try file("source/planned", "data")
        let target = try directory("target/source")
        var added = false
        let result = run([source], target.deletingLastPathComponent(), progress: { update in
            if update.phase == "Копирование" && update.fileBytes > 0 && !added {
                added = true
                _ = try? self.file("source/new-unplanned", "retain")
            }
        }, conflict: { _ in .merge })
        #expect(result.completed == 1 && result.failed == 1)
        #expect(!result.issues.isEmpty)
        #expect(try text(planned) == "data")
        #expect(try text(target.appendingPathComponent("planned")) == "data")
        #expect(!fm.fileExists(atPath: target.appendingPathComponent("new-unplanned").path))
    }

    @Test(arguments: [false, true])
    func nestedPackageMoveUsesPathReceiptsAcrossTemporaryAliases(alias: Bool) throws {
        let name = "FarMac-NestedMove-\(UUID().uuidString)"
        let physical = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        let visible = URL(fileURLWithPath: alias ? "/tmp" : "/private/tmp", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: physical, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: physical) }
        let source = visible.appendingPathComponent("Input.app", isDirectory: true)
        let nested = source.appendingPathComponent("Contents/Resources/nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: nested.appendingPathComponent("payload"))
        try fm.createSymbolicLink(atPath: nested.appendingPathComponent("link").path, withDestinationPath: "payload")
        let destination = visible.appendingPathComponent("Output.app")
        let result = run([source], destination, move: true)
        #expect(result.completed == 2 && result.failed == 0 && !result.cancelled, "\(result.issues)")
        #expect(!fm.fileExists(atPath: source.path))
        let output = destination.appendingPathComponent("Contents/Resources/nested", isDirectory: true)
        #expect(try text(output.appendingPathComponent("payload")) == "payload")
        #expect(try fm.destinationOfSymbolicLink(atPath: output.appendingPathComponent("link").path) == "payload")
    }

}
