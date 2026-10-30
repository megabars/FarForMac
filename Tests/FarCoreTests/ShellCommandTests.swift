import Foundation
import Testing
@testable import FarCore

@Suite
struct ShellCommandTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FarShellTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func quotedArgumentsRoundTripThroughPOSIXShellWithoutInjection() throws {
        let values = ["", "plain", "two words", "it's", "Юникод🦉", "$(printf injected); & | > * ? [x]", "line\nbreak", "\\\"' $HOME `id`"]
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\0' " + (try values.map(ShellCommand.quoteArgument).joined(separator: " "))]
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let expected = values.reduce(into: Data()) { $0.append(Data($1.utf8)); $0.append(0) }
        #expect(bytes == expected)
        #expect(throws: ShellCommandError.nullByte) { try ShellCommand.quoteArgument("bad\0argument") }
    }

    @Test
    func literalCDHandlesQuotingUnicodeHomePreviousAndOptions() throws {
        let current = URL(fileURLWithPath: "/tmp/current")
        let home = URL(fileURLWithPath: "/tmp/home")
        #expect(try ShellCommand.directoryChange(in: "cd 'folder with пробел'", currentDirectory: current)?.path == "/tmp/current/folder with пробел")
        #expect(try ShellCommand.directoryChange(in: "cd 'it'\\''s'", currentDirectory: current)?.path == "/tmp/current/it's")
        #expect(try ShellCommand.directoryChange(in: "cd double\\ space", currentDirectory: current)?.path == "/tmp/current/double space")
        #expect(try ShellCommand.directoryChange(in: "cd", currentDirectory: current, homeDirectory: home) == home)
        #expect(try ShellCommand.directoryChange(in: "cd ~/документы", currentDirectory: current, homeDirectory: home)?.path == "/tmp/home/документы")
        #expect(try ShellCommand.directoryChange(in: "cd '~'", currentDirectory: current)?.path == "/tmp/current/~")
        #expect(try ShellCommand.directoryChange(in: "cd -", currentDirectory: current, previousDirectory: home) == home)
        #expect(try ShellCommand.directoryChange(in: "cd -- -", currentDirectory: current)?.path == "/tmp/current/-")
        #expect(try ShellCommand.directoryChange(in: "cd '-'", currentDirectory: current)?.path == "/tmp/current/-")
        #expect(throws: ShellCommandError.previousDirectoryUnavailable) {
            try ShellCommand.directoryChange(in: "cd -", currentDirectory: current)
        }
    }

    @Test
    func shellSyntaxNeverChangesPanelDirectory() throws {
        let current = URL(fileURLWithPath: "/tmp")
        for text in ["echo cd /", "cd / && pwd", "cd /; pwd", "cd /\npwd", "cd / | cat", "cd / > out", "X=1 cd /", "cd $HOME", "cd \"$HOME\"", "cd $(pwd)", "cd `pwd`", "cd *", "cd ~someone", "cd -P /", "cd a b", "cd <(pwd)", "echo ok # don't parse comment quotes", "cat <<'EOF'\n'hello\nEOF", "cd / # don't parse comment quotes"] {
            #expect(try ShellCommand.directoryChange(in: text, currentDirectory: current) == nil, "\(text)")
        }
        #expect(try ShellCommand.directoryChange(in: "cd '$HOME'", currentDirectory: current)?.path == "/tmp/$HOME")
        #expect(throws: ShellCommandError.invalidSyntax) { try ShellCommand.directoryChange(in: "cd 'unfinished", currentDirectory: current) }
        #expect(throws: ShellCommandError.tooLong) {
            try ShellCommand.directoryChange(in: String(repeating: "a", count: 65_537), currentDirectory: current)
        }
    }

    @Test
    func completionReplacesEntireQuotedLastTokenAndKeepsPrefix() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "it's a $(bad) Юникод.txt"
        let file = directory.appendingPathComponent(name)
        try Data().write(to: file)
        try Data().write(to: directory.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder space"), withIntermediateDirectories: true)
        let result = try ShellCommand.completePath(in: "printf '%s' 'it", currentDirectory: directory)
        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.path == file.path)
        #expect(result.candidates.first?.commandLine == "printf '%s' " + (try ShellCommand.quoteArgument(file.path)))
        let folders = try ShellCommand.completePath(in: "cd fold", currentDirectory: directory)
        #expect(folders.candidates.first?.isDirectory == true)
        #expect(folders.candidates.first?.commandLine == "cd " + (try ShellCommand.quoteArgument(directory.appendingPathComponent("folder space").path + "/")))
        let all = try ShellCommand.completePath(in: "echo ", currentDirectory: directory)
        #expect(all.candidates.count == 2)
        #expect(try ShellCommand.completePath(in: "echo .", currentDirectory: directory).candidates.count == 1)
        #expect(throws: ShellCommandError.unsupportedSyntax) { try ShellCommand.completePath(in: "echo $HOME", currentDirectory: directory) }
        #expect(throws: ShellCommandError.unsupportedSyntax) { try ShellCommand.completePath(in: "echo x; echo y", currentDirectory: directory) }
        #expect(throws: ShellCommandError.self) { try ShellCommand.completePath(in: "echo missing/file", currentDirectory: directory) }
    }

    @Test
    func completionReportsScanAndResultBounds() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for number in 0..<1_005 { try Data().write(to: directory.appendingPathComponent("file\(number)")) }
        let result = try ShellCommand.completePath(in: "echo ", currentDirectory: directory, maximumResults: 2_000, maximumScannedEntries: 2_000)
        #expect(result.scannedEntryCount == 1_000)
        #expect(result.candidates.count == 1_000)
        #expect(result.isTruncated)
        let limited = try ShellCommand.completePath(in: "echo ", currentDirectory: directory, maximumResults: 2, maximumScannedEntries: 10)
        #expect(limited.scannedEntryCount == 10)
        #expect(limited.candidates.count == 2)
        #expect(limited.isTruncated)
    }
}
