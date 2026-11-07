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
             options: LocalTransferOptions? = nil,
             cancellation: TransferCancellation = TransferCancellation(),
             progress: @escaping (TransferProgress) -> Void = { _ in },
             conflict: @escaping (TransferConflict) -> TransferDecision = { _ in .skip },
             error: @escaping (TransferFailure) -> TransferErrorDecision = { _ in .skip }) -> TransferResult {
        TransferEngine.run(TransferRequest(sources: sources, destination: target, move: move, localOptions: options), cancellation: cancellation,
                           onProgress: progress, onConflict: conflict, onError: error)
    }
    func staging(_ directory: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".farmac-transfer-") }
    }

    @Test func farDestinationListsPreserveQuotedDelimitersAndDirectoryIntent() throws {
        let targets = try LocalTransferDestination.parse(#" "quoted,a/" ; dir/*.bak , other/ "#, relativeTo: root, multiple: true)
        #expect(targets.map { $0.url.path } == [root.appendingPathComponent("quoted,a").path,
                root.appendingPathComponent("dir/*.bak").path, root.appendingPathComponent("other").path])
        #expect(targets.map(\.forceDirectory) == [true, false, true])
        #expect(try LocalTransferDestination.parse("a;b", relativeTo: root, multiple: false).count == 1)
        for invalid in ["a;\"unclosed", "a; ", "a;./a", "*/name", "*.bak/"] {
            #expect(throws: (any Error).self) { try LocalTransferDestination.parse(invalid, relativeTo: root, multiple: true) }
        }
    }

    @Test func destinationListRejectsDirectoryAliasesAndPathsBelowAliasedParents() throws {
        let destination = try directory("Destination")
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: destination)
        for duplicate in ["Destination/;alias/", "Destination/new/item;alias/new/item"] {
            #expect(throws: (any Error).self) { try LocalTransferDestination.parse(duplicate, relativeTo: root, multiple: true) }
        }
        if try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false {
            #expect(throws: (any Error).self) {
                try LocalTransferDestination.parse("alias/New/item;Destination/new/Item", relativeTo: root, multiple: true)
            }
        }
        let distinct = try LocalTransferDestination.parse("alias/one;Destination/two", relativeTo: root, multiple: true)
        #expect(distinct.map(\.url.path) == [alias.appendingPathComponent("one").path, destination.appendingPathComponent("two").path])
    }

    @Test func destinationSyntaxPreservesLiteralFilenameWhitespace() throws {
        let single = try LocalTransferDestination.parse(" report ", relativeTo: root, multiple: false)
        let quoted = try LocalTransferDestination.parse("\" report \"", relativeTo: root, multiple: false)
        let list = try LocalTransferDestination.parse(" \" report \" ; \"./~ report \" ", relativeTo: root, multiple: true)
        #expect(single.first?.url.path == root.appendingPathComponent(" report ").path)
        #expect(quoted == single)
        #expect(list.map(\.url.path) == [root.appendingPathComponent(" report ").path, root.appendingPathComponent("~ report ").path])
    }

    @Test func destinationListRejectsOverlappingEffectiveNamesBeforeQueuing() throws {
        let source = try file("report.txt")
        _ = try directory("out/nested")
        for input in ["out/;out/report.txt", "out/*.txt;out/report.txt", "missing/;missing/report.txt"] {
            let destinations = try LocalTransferDestination.parse(input, relativeTo: root, multiple: true)
            #expect(throws: (any Error).self) {
                try LocalTransferDestination.validateDistinctTargets(destinations, sources: [source])
            }
        }
        let distinct = try LocalTransferDestination.parse("out/;out/nested/;out/report.bak", relativeTo: root, multiple: true)
        try LocalTransferDestination.validateDistinctTargets(distinct, sources: [source])
    }

    @Test func farMasksApplyPerSourceAndCreateParentsDuringCopyAndMove() throws {
        let first = try file("report.part.txt", "one")
        let second = try file("other.txt", "two")
        let destination = root.appendingPathComponent("new/sub/*.bak")
        let copied = run([first, second], destination, options: LocalTransferOptions())
        #expect(copied.completed == 2 && copied.failed == 0)
        #expect(try text(root.appendingPathComponent("new/sub/report.part.bak")) == "one")
        #expect(try text(root.appendingPathComponent("new/sub/other.bak")) == "two")
        let moved = run([first], root.appendingPathComponent("*.old"), move: true, options: LocalTransferOptions())
        #expect(moved.completed == 1 && !fm.fileExists(atPath: first.path))
        #expect(try text(root.appendingPathComponent("report.part.old")) == "one")
    }

    @Test func newFolderDestinationPreservesDirectoryRuleAndRejectsSelfDescendants() throws {
        let source = try directory("source")
        _ = try file("source/item", "payload")
        let invalid = run([source], source.appendingPathComponent("missing/sub"), options: LocalTransferOptions(forceDirectory: true))
        #expect(invalid.completed == 0 && invalid.failed == 1)
        #expect(!fm.fileExists(atPath: source.appendingPathComponent("missing").path))
        let direct = root.appendingPathComponent("direct")
        #expect(run([source], direct, options: LocalTransferOptions()).completed == 1)
        #expect(try text(direct.appendingPathComponent("item")) == "payload")
        let explicit = root.appendingPathComponent("explicit/sub")
        #expect(run([source], explicit, options: LocalTransferOptions(forceDirectory: true)).completed == 1)
        #expect(try text(explicit.appendingPathComponent("source/item")) == "payload")
    }

    @Test func filterUsesPrioritySizesAndDatesAndLeavesExcludedMoveSources() throws {
        let source = try directory("source")
        _ = try directory("source/empty")
        _ = try file("source/empty/tiny.txt", "a")
        let kept = try file("source/good.txt", "abcd")
        let secret = try file("source/private.txt", "secret")
        let included = try file("source/required.bin", "raw")
        let stale = try file("source/stale.txt", "stale")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: date.addingTimeInterval(-1)], ofItemAtPath: stale.path)
        let options = LocalTransferOptions(filterRules: [
            LocalTransferFilterRule(action: .include, mask: "*.txt", minBytes: 2, earliest: date),
            LocalTransferFilterRule(action: .priorityExclude, mask: "private.*"),
            LocalTransferFilterRule(action: .priorityInclude, mask: "required.bin")
        ])
        let destination = root.appendingPathComponent("out")
        let result = run([source], destination, move: true, options: options)
        #expect(result.completed == 2 && result.failed == 0 && result.issues.isEmpty)
        #expect(!fm.fileExists(atPath: kept.path) && !fm.fileExists(atPath: included.path))
        #expect(try text(secret) == "secret")
        #expect(try text(stale) == "stale")
        #expect(try text(destination.appendingPathComponent("good.txt")) == "abcd")
        #expect(try text(destination.appendingPathComponent("required.bin")) == "raw")
        #expect(!fm.fileExists(atPath: destination.appendingPathComponent("empty").path))
        let noMatches = root.appendingPathComponent("no-matches/unused")
        let empty = run([source], noMatches, options: LocalTransferOptions(forceDirectory: true, filterRules: [
            LocalTransferFilterRule(mask: "no-match.txt")
        ]))
        #expect(empty.completed == 0 && empty.failed == 0)
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("no-matches").path))
        #expect(try LocalTransferFilterRule.parseSize("1K") == 1024)
        #expect(try LocalTransferFilterRule.parseSize("1k") == 1000)
        #expect(throws: (any Error).self) { try LocalTransferFilterRule.parseSize("999E") }
    }

    @Test func folderOnlyIncludeDoesNotTransferUnmatchedFiles() throws {
        let source = try directory("source")
        let retained = try file("source/report.txt", "keep")
        let destination = root.appendingPathComponent("out")
        let rules = [LocalTransferFilterRule(scope: .directories, mask: "source")]
        let result = run([source], destination, move: true, options: LocalTransferOptions(filterRules: rules))
        #expect(result.completed == 0 && result.failed == 0)
        #expect(try text(retained) == "keep")
        #expect(!fm.fileExists(atPath: destination.path))
    }

    @Test func newerAndRenamePoliciesHandleWriteTimeAndOccupiedSuffixes() throws {
        let input = try directory("input"), output = try directory("output")
        let source = try file("input/report.txt", "updated")
        let target = try file("output/report.txt", "old")
        let occupied = try file("output/report (2).txt", "existing")
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
        let options = LocalTransferOptions(conflictPolicy: .newer)
        #expect(run([source], output, options: options).skipped == 1)
        try fm.setAttributes([.modificationDate: date.addingTimeInterval(1)], ofItemAtPath: source.path)
        #expect(run([source], output, options: options).completed == 1)
        #expect(try text(target) == "updated")
        #expect(run([source], output, options: LocalTransferOptions(conflictPolicy: .rename)).completed == 1)
        #expect(try text(occupied) == "existing")
        #expect(try text(output.appendingPathComponent("report (3).txt")) == "updated")
        #expect(fm.fileExists(atPath: input.path))
    }

    @Test func appendConfirmsReadOnlyAndPreservesOriginalOnCancellation() throws {
        let source = try file("from", "new")
        let destination = try file("to", "old")
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
        let options = LocalTransferOptions(conflictPolicy: .append, confirmReadOnly: true)
        var prompts: [TransferConflict] = []
        let skipped = run([source], destination, options: options, conflict: { prompts.append($0); return .skip })
        #expect(skipped.skipped == 1)
        #expect(prompts.count == 1 && prompts.first?.isReadOnlyConfirmation == true && prompts.first?.canAppend == true)
        #expect(try text(destination) == "old")
        let token = TransferCancellation()
        let cancelled = run([source], destination, move: true, options: options, cancellation: token, progress: { update in
            if update.phase == "Копирование" && update.fileBytes == 3 { token.cancel() }
        }, conflict: { _ in .replace })
        #expect(cancelled.cancelled)
        #expect(try text(destination) == "old")
        #expect(try text(source) == "new")
        #expect(try staging(root).isEmpty)
        let complete = run([source], destination, move: true, options: options, conflict: { _ in .replace })
        #expect(complete.completed == 1 && complete.failed == 0)
        #expect(try text(destination) == "oldnew")
        #expect(!fm.fileExists(atPath: source.path))
        #expect(try FileTools.metadata(destination).permissions == 0o444)
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

extension TransferEngineTests {
    @Test func descriptionsFollowCopyMoveAndConflictRename() throws {
        let source = try file("original", "content"), target = try directory("destination")
        _ = try file("descript.ion", "original Описание\nkeep\t  exact bytes  \r\n")
        let copy = run([source], target)
        #expect(copy.failed == 0 && copy.issues.isEmpty)
        #expect(try FileDescriptions.load(directory: target).description(for: "original") == "Описание")
        #expect(try FileDescriptions.load(directory: root).description(for: "original") == "Описание")
        let moved = run([source], target, move: true, conflict: { _ in .rename("renamed") })
        #expect(moved.failed == 0 && moved.issues.isEmpty)
        #expect(!fm.fileExists(atPath: source.path))
        #expect(try FileDescriptions.load(directory: root).description(for: "original").isEmpty)
        #expect(try FileDescriptions.load(directory: target).description(for: "renamed") == "Описание")
        #expect(try text(root.appendingPathComponent("descript.ion")) == "keep\t  exact bytes  \r\n")
    }

    @Test func skippedAndCancelledCopiesLeaveDescriptionBytesUntouched() throws {
        let source = try file("source"), target = try file("target")
        let metadata = try file("descript.ion", "source first\ntarget second\n")
        let original = try Data(contentsOf: metadata)
        let skip = run([source], target, move: true)
        #expect(skip.skipped == 1)
        #expect(try Data(contentsOf: metadata) == original)
        let token = TransferCancellation()
        let cancel = run([source], root.appendingPathComponent("copy"), move: true, cancellation: token, progress: { progress in
            if progress.phase == "Копирование" { token.cancel() }
        })
        #expect(cancel.cancelled)
        #expect(try Data(contentsOf: metadata) == original)
        #expect(fm.fileExists(atPath: source.path))
    }

    @Test func overwriteUpdatesOnlyCopiedRecordAndAbsentSourceRecordPreservesTarget() throws {
        let source = try file("source", "new"), target = try directory("destination")
        _ = try file("destination/source", "old")
        _ = try file("descript.ion", "source new description\n")
        _ = try file("destination/descript.ion", "source old description\nkeep\t exact spacing  \r\n")
        let replaced = run([source], target, conflict: { _ in .replace })
        #expect(replaced.failed == 0 && replaced.issues.isEmpty)
        #expect(try text(target.appendingPathComponent("descript.ion")) == "source new description\nkeep\t exact spacing  \r\n")
        try Data().write(to: root.appendingPathComponent("descript.ion"))
        _ = run([source], target, conflict: { _ in .replace })
        #expect(try FileDescriptions.load(directory: target).description(for: "source") == "new description")
    }

    @Test func concurrentDestinationMetadataKeepsPublishedCopyAndMoveSource() throws {
        let source = try file("source"), target = try directory("destination")
        _ = try file("descript.ion", "source source description\n")
        let metadata = try file("destination/descript.ion", "keep initial\n")
        var changed = false
        var errorPrompts = 0
        let result = run([source], target, move: true, progress: { progress in
            if progress.phase == "Копирование", !changed {
                changed = true
                try? Data("keep external\n".utf8).write(to: metadata)
            }
        }, error: { _ in errorPrompts += 1; return .retry })
        #expect(result.completed == 1 && result.failed == 0 && !result.issues.isEmpty)
        #expect(errorPrompts == 0)
        #expect(fm.fileExists(atPath: source.path))
        #expect(try text(target.appendingPathComponent("source")) == "data")
        #expect(try text(metadata) == "keep external\n")
        #expect(result.summary.contains("частично"))
    }

    @Test func malformedMetadataAndExplicitOptOutNeverLoseFilesOrRewriteMetadata() throws {
        let source = try file("source"), target = try directory("destination")
        let metadata = try file("descript.ion", "source first\nsource duplicate\n")
        let result = run([source], target, move: true)
        #expect(result.completed == 1 && !result.issues.isEmpty)
        #expect(fm.fileExists(atPath: source.path))
        #expect(try text(metadata) == "source first\nsource duplicate\n")
        let disabled = TransferEngine.run(TransferRequest(sources: [source], destination: target.appendingPathComponent("disabled"), move: true, propagateDescriptions: false), cancellation: TransferCancellation(), onProgress: { _ in }, onConflict: { _ in .skip }, onError: { _ in .skip })
        #expect(disabled.issues.isEmpty && !fm.fileExists(atPath: source.path))
        #expect(try text(metadata) == "source first\nsource duplicate\n")
    }

    @Test func cancellationDuringSourceRemovalKeepsBothDescriptions() throws {
        let source = try file("source"), target = try directory("destination")
        _ = try file("descript.ion", "source keep\n")
        let token = TransferCancellation()
        let result = run([source], target, move: true, cancellation: token, progress: { progress in
            if progress.phase == "Удаление источника" { token.cancel() }
        })
        #expect(result.cancelled && fm.fileExists(atPath: source.path))
        #expect(try FileDescriptions.load(directory: root).description(for: "source") == "keep")
        #expect(try FileDescriptions.load(directory: target).description(for: "source") == "keep")
    }

    @Test func directoryMergePreservesDestinationOnlyAndSkippedDescriptionRecords() throws {
        let source = try directory("source"), target = try directory("destination")
        _ = try directory("destination/source")
        _ = try file("source/moved")
        _ = try file("source/skipped")
        _ = try file("source/descript.ion", "moved move description\nskipped source description\n")
        _ = try file("destination/source/skipped", "existing")
        let destinationMetadata = try file("destination/source/descript.ion", "keep\t exact bytes  \r\nskipped destination description\n")
        let result = run([source], target, move: true, conflict: { $0.isDirectoryMerge ? .merge : .skip })
        #expect(result.skipped == 1 && result.failed == 0)
        #expect(try FileDescriptions.load(directory: source).descriptions == ["skipped": "source description"])
        #expect(try FileDescriptions.load(directory: target.appendingPathComponent("source")).descriptions == ["keep": "exact bytes", "skipped": "destination description", "moved": "move description"])
        #expect(try text(destinationMetadata).contains("keep\t exact bytes  \r\n"))
        #expect(try text(target.appendingPathComponent("source/skipped")) == "existing")
    }

    @Test func freshDirectoryCopyPreservesNestedDescriptionBytes() throws {
        let source = try directory("source"), target = try directory("destination")
        _ = try file("source/data")
        let raw = Data([0xFE, 0xFF, 0x80])
        try raw.write(to: source.appendingPathComponent("descript.ion"))
        let result = run([source], target)
        #expect(result.failed == 0 && result.issues.isEmpty)
        #expect(try Data(contentsOf: target.appendingPathComponent("source/descript.ion")) == raw)
    }

    @Test(arguments: [true, false])
    func filteredFreshMovePartitionsDescriptionRecords(controlMatchesFilter: Bool) throws {
        let source = try directory("source"), target = root.appendingPathComponent("new")
        let moved = try file("source/moved.txt", "move data")
        let kept = try file("source/kept.bin", "keep data")
        let control = try file("source/descript.ion", "kept.bin\t keep description  \r\nmoved.txt move description\n")
        let rules = [LocalTransferFilterRule(mask: controlMatchesFilter ? "*.txt,descript.ion" : "*.txt")]
        let result = run([source], target, move: true, options: LocalTransferOptions(filterRules: rules))
        #expect(result.failed == 0 && result.issues.isEmpty)
        #expect(!fm.fileExists(atPath: moved.path))
        #expect(try text(kept) == "keep data")
        #expect(try text(control) == "kept.bin\t keep description  \r\n")
        #expect(try text(target.appendingPathComponent("moved.txt")) == "move data")
        #expect(try FileDescriptions.load(directory: target).descriptions == ["moved.txt": "move description"])
    }

    @Test func filteredFreshMovePreservesSourceWhenPublishedDescriptionChanges() throws {
        let source = try directory("source"), target = root.appendingPathComponent("new")
        let moved = try file("source/moved.txt")
        _ = try file("source/kept.bin")
        let control = try file("source/descript.ion", "moved.txt source description\n")
        let published = target.appendingPathComponent("descript.ion")
        var replaced = false
        let result = run([source], target, move: true, options: LocalTransferOptions(filterRules: [LocalTransferFilterRule(mask: "*.txt")]), progress: { event in
            if event.phase == "Удаление источника", !replaced {
                replaced = true
                try! Data("moved.txt concurrent description\n".utf8).write(to: published)
            }
        })
        #expect(replaced && result.failed > 0)
        #expect(fm.fileExists(atPath: moved.path))
        #expect(try text(control) == "moved.txt source description\n")
        #expect(try text(published) == "moved.txt concurrent description\n")
    }
}

extension TransferEngineTests {
    @Test func completelyMergedMoveRemovesOnlyEmptiedControlFile() throws {
        let source = try directory("source"), target = try directory("destination")
        _ = try directory("destination/source")
        _ = try file("source/one")
        let two = try file("source/two")
        _ = try file("source/descript.ion", "one first\ntwo second\n")
        let result = run([source], target, move: true, conflict: { $0.isDirectoryMerge ? .merge : .skip })
        #expect(result.failed == 0 && result.issues.isEmpty)
        #expect(!fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: two.path))
        #expect(try FileDescriptions.load(directory: target.appendingPathComponent("source")).descriptions == ["one": "first", "two": "second"])
    }

    @Test func explicitlySelectedControlFileIsNeverRewrittenBySiblingTransfer() throws {
        let source = try file("source"), metadata = try file("descript.ion", "source first\n"), target = try directory("destination")
        let original = try Data(contentsOf: metadata)
        let result = run([source, metadata], target, move: true)
        #expect(result.failed == 0 && result.issues.isEmpty)
        #expect(!fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: metadata.path))
        #expect(try Data(contentsOf: target.appendingPathComponent("descript.ion")) == original)
    }
}

extension TransferEngineTests {
    @Test func managedMergeBudgetCountsPayloadAndEmptyContainerWithoutControlFileBytes() throws {
        for hasPayload in [true, false] {
            let suffix = hasPayload ? "payload" : "control-only"
            let source = try directory("source-" + suffix), destination = try directory("destination-" + suffix)
            _ = try directory("destination-" + suffix + "/source-" + suffix)
            let original = "data description\n"
            _ = try file("source-" + suffix + "/descript.ion", original)
            if hasPayload { _ = try file("source-" + suffix + "/data", "1234") }
            var finalProgress: TransferProgress?
            let result = run([source], destination, progress: { finalProgress = $0 }, conflict: { _ in .merge })
            #expect(result.completed == 1 && result.failed == 0 && result.skipped == 0 && result.issues.isEmpty)
            #expect(result.summary.hasPrefix("Операция завершена."))
            #expect(finalProgress?.completedItems == 1 && finalProgress?.totalItems == 1)
            #expect(finalProgress?.completedBytes == (hasPayload ? 4 : 0))
            #expect(finalProgress?.totalBytes == (hasPayload ? 4 : 0))
            #expect(try text(source.appendingPathComponent("descript.ion")) == original)
            let target = destination.appendingPathComponent(source.lastPathComponent)
            if hasPayload { #expect(try FileDescriptions.load(directory: target).description(for: "data") == "description") }
            else { #expect(!fm.fileExists(atPath: target.appendingPathComponent("descript.ion").path)) }
        }
    }

    @Test func cancelledDirectoryMoveRetainsControlFileUntilLastPayloadIsRemoved() throws {
        let source = try directory("source"), destination = try directory("destination")
        _ = try file("source/a-data", "first")
        let remaining = try file("source/z-data", "last")
        let original = Data("a-data first description\nz-data remaining description\n".utf8)
        let metadata = source.appendingPathComponent("descript.ion")
        try original.write(to: metadata)
        let token = TransferCancellation()
        let result = run([source], destination, move: true, cancellation: token, progress: { progress in
            if progress.phase == "Удаление источника", URL(fileURLWithPath: progress.currentPath).lastPathComponent == "z-data" { token.cancel() }
        })
        #expect(result.cancelled && result.completed == 3)
        #expect(!fm.fileExists(atPath: source.appendingPathComponent("a-data").path))
        #expect(try text(remaining) == "last")
        #expect(try Data(contentsOf: metadata) == original)
        #expect(try Data(contentsOf: destination.appendingPathComponent("source/descript.ion")) == original)
        #expect(try FileDescriptions.load(directory: source).description(for: "z-data") == "remaining description")
    }
}

extension TransferEngineTests {
    @Test func mergedMoveRetainsSourceDirectoryWhenParentDescriptionAppearsConcurrently() throws {
        let source = try directory("source"), destination = try directory("destination")
        _ = try directory("destination/source")
        _ = try file("source/data", "published")
        let metadata = root.appendingPathComponent("descript.ion")
        var changed = false
        let result = run([source], destination, move: true, progress: { progress in
            if progress.phase == "Копирование", !changed {
                changed = true
                try? Data("source externally added description\n".utf8).write(to: metadata)
            }
        }, conflict: { _ in .merge })
        #expect(result.completed == 1 && !result.issues.isEmpty)
        #expect(fm.fileExists(atPath: source.path))
        #expect(try text(metadata) == "source externally added description\n")
        #expect(try text(destination.appendingPathComponent("source/data")) == "published")
    }
}
