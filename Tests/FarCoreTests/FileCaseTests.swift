import Foundation
import Testing
@testable import FarCore

@Suite struct FileCaseTests {
    @Test func transformationsMatchIndependentNameExtensionAndDelimiterOptions() {
        let defaults = FileCaseOptions()
        #expect(FileCase.convertedName("MiXeD.TXT", isDirectory: false, options: defaults) == "MiXeD.txt")
        #expect(FileCase.convertedName("UPPER.MiX", isDirectory: false, options: defaults) == "upper.MiX")
        #expect(FileCase.convertedName(".ENV", isDirectory: false, options: defaults) == ".env")
        #expect(FileCase.convertedName("NAME.", isDirectory: false, options: defaults) == "name.")
        let title = FileCaseOptions(name: .title, fileExtension: .upper, skipMixedCase: false, wordDelimiters: " -")
        #expect(FileCase.convertedName("ANOTHER-LONG_NAME.Txt", isDirectory: false, options: title) == "Another-Long_name.TXT")
        let first = FileCaseOptions(name: .first, fileExtension: .unchanged, skipMixedCase: false)
        #expect(FileCase.convertedName("2CAPS.TxT", isDirectory: false, options: first) == "2caps.TxT")
        #expect(FileCase.convertedName("UPPER.DIR", isDirectory: true, options: defaults) == "UPPER.DIR")
    }

    @Test func recursiveFolderRenamesRunBottomUpAndNeverTraverseSymlinkTargets() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("INPUT", isDirectory: true)
        let child = input.appendingPathComponent("CHILD", isDirectory: true)
        let outside = root.appendingPathComponent("OUTSIDE", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: child.appendingPathComponent("DATA.TXT"))
        try Data("untouched".utf8).write(to: outside.appendingPathComponent("EXTERNAL.TXT"))
        try FileManager.default.createSymbolicLink(at: input.appendingPathComponent("LINK"), withDestinationURL: outside)

        let options = FileCaseOptions(recurse: true, renameDirectories: true)
        #expect(try FileCase.rename([input], options: options) == 4)
        let output = root.appendingPathComponent("input", isDirectory: true)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["input", "OUTSIDE"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)) == ["child", "link"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("child").path) == ["data.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["EXTERNAL.TXT"])
        #expect(try Data(contentsOf: output.appendingPathComponent("child/data.txt")) == Data("file".utf8))
    }

    @Test func conflictingCaseExpansionPreflightsAllGroupsBeforeMutation() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("folder1", isDirectory: true)
        let second = root.appendingPathComponent("folder2", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: first.appendingPathComponent("small.txt"))
        let source = second.appendingPathComponent("straße.txt")
        let target = second.appendingPathComponent("STRASSE.TXT")
        try Data("source".utf8).write(to: source)
        // Some file systems already treat sharp-S and SS as aliases.
        // The distinct-name hard-link test covers these volumes separately.
        if FileManager.default.fileExists(atPath: target.path) { return }
        try Data("target".utf8).write(to: target)
        let options = FileCaseOptions(name: .upper, fileExtension: .upper, recurse: true)
        #expect(throws: (any Error).self) { try FileCase.rename([first, second], options: options) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.path) == ["small.txt"])
        #expect(try Data(contentsOf: source) == Data("source".utf8))
        #expect(try Data(contentsOf: target) == Data("target".utf8))
    }

    @Test func caseOnlyModeNeverAllowsReplacingAnotherHardLink() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SOURCE.TXT")
        try Data("contents".utf8).write(to: source)
        let lowercase = root.appendingPathComponent("source.txt")
        let sensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        let hardLink = sensitive ? lowercase : root.appendingPathComponent("OTHER.TXT")
        try FileManager.default.linkItem(at: source, to: hardLink)
        let plan = [BatchRenameEntry(source: try FileTools.metadata(source), destination: hardLink)]
        #expect(throws: (any Error).self) { try FileTools.executeRename(plan, allowCaseOnly: true) }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set([source.lastPathComponent, hardLink.lastPathComponent]))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("filecase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
