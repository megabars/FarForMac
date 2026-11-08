import Foundation
import Testing
@testable import FarCore

@Suite("FAR Commands prefix and output contracts")
struct FarCmdsTests {
    @Test func prefixesAndPosition() throws {
        let view = try FarCmdsCommand(prefix: .view, arguments: " \"one two.txt\" ")
        #expect(view.operand == .path("one two.txt"))
        let editor = try FarCmdsCommand(prefix: .edit, arguments: "[%ROW%,] \"file.txt\"", environment: ["ROW": "4"])
        #expect(editor.position == .init(line: 4, column: 1))
        #expect(editor.operand == .path("file.txt"))
        let brackets = try FarCmdsCommand(prefix: .edit, arguments: " [1].txt")
        #expect(brackets.position == nil)
        #expect(brackets.operand == .path("[1].txt"))
        for prefix in [FarCmdsPrefix.goto, .whereis, .load, .unload] {
            #expect(try FarCmdsCommand(prefix: prefix, arguments: "< \"path file.txt\"").operand == .pathInFile("path file.txt"))
        }
        let link = try FarCmdsCommand(prefix: .link, arguments: "/MSG /n /s \"a b\" \"c d\"")
        #expect(link.operand == .link(.init(source: "a b", destination: "c d", symbolic: true, refresh: false, showErrors: true)))
        let slash = try FarCmdsCommand(prefix: .link, arguments: "/net/item /new/path")
        #expect(slash.operand == .link(.init(source: "/net/item", destination: "/new/path", symbolic: false, refresh: true, showErrors: false)))
        #expect(throws: FarCmdsError.self) { try FarCmdsCommand(prefix: .run, arguments: "missing marker") }
    }

    @Test func captureGrammar() throws {
        let options = FarCmdsOptions(display: .echo, stream: .stderr)
        let hidden = try FarCmdsCommand(prefix: .view, arguments: "<*>\"printf\" %VALUE%", options: options, environment: ["Value": "done"])
        #expect(hidden.operand == .capture(.init(command: "\"printf\" done", directory: nil, stream: .combined, display: .hide, destination: nil)))
        let separated = try FarCmdsCommand(prefix: .edit, arguments: "[,3] <?+|%TEMP%|printf hi", environment: ["TEMP": "/tmp"])
        #expect(separated.position == .init(line: 1, column: 3))
        #expect(separated.operand == .capture(.init(command: "printf hi", directory: "/tmp", stream: .separate, display: .keep, destination: nil)))
        let run = try FarCmdsCommand(prefix: .run, arguments: "\"test<output\"<?+echo yes")
        #expect(run.operand == .capture(.init(command: "echo yes", directory: nil, stream: .combined, display: .echo, destination: "test<output")))
        let defaults = try FarCmdsCommand(prefix: .clip, arguments: "<printf yes", options: options)
        #expect(defaults.operand == .capture(.init(command: "printf yes", directory: nil, stream: .stderr, display: .echo, destination: nil)))
        #expect(throws: FarCmdsError.self) { try FarCmdsCommand(prefix: .view, arguments: "<|/tmp command") }
    }

    @Test func actualStreamsAndEnvironment() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = "printf '%s' \"$FROM_FAR\"; printf 'error' >&2"
        let environment = ["PATH": "/usr/bin:/bin", "FROM_FAR": "output"]
        let runner = FarCmdsCaptureRunner(timeout: 5)
        for (stream, expected) in [(FarCmdsStream.combined, "outputerror"), (.stdout, "output"), (.stderr, "error"), (.separate, "output")] {
            let capture = FarCmdsCommand.Capture(command: shell, directory: nil, stream: stream, display: .keep, destination: nil)
            let result = try runner.run(capture, directory: folder, environment: environment)
            #expect(result.primary == Data(expected.utf8))
            #expect(result.standardError == (stream == .separate ? Data("error".utf8) : nil))
            #expect(result.exitCode == 0)
            if stream == .stdout { #expect(result.console == Data("error".utf8)) }
            if stream == .stderr { #expect(result.console == Data("output".utf8)) }
        }
        let capture = FarCmdsCommand.Capture(command: "pwd; exit 7", directory: nil, stream: .combined, display: .echo, destination: nil)
        let result = try runner.run(capture, directory: folder, environment: environment)
        #expect(String(decoding: result.primary, as: UTF8.self).trimmingCharacters(in: .newlines).hasSuffix(folder.lastPathComponent))
        #expect(result.console == result.primary)
        #expect(result.exitCode == 7)
    }

    @Test func captureCancellationAndLimits() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        func command(_ text: String) -> FarCmdsCommand.Capture {
            .init(command: text, directory: nil, stream: .combined, display: .hide, destination: nil)
        }
        let token = ExtensionCancellation()
        let ready = root.appendingPathComponent("capture-started")
        // The runner blocks its calling thread. Observe readiness on a separate
        // thread so a busy test pool cannot delay the cancellation callback.
        let observer = Thread {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !Thread.current.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                if FileManager.default.fileExists(atPath: ready.path) {
                    token.cancel()
                    return
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        observer.start()
        defer { observer.cancel() }
        #expect(throws: CancellationError.self) {
            try FarCmdsCaptureRunner(timeout: 15).run(command(": > capture-started; exec /bin/sleep 60"),
                                                       directory: root, environment: [:], cancellation: token)
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        #expect(throws: FarCmdsError.self) {
            try FarCmdsCaptureRunner(timeout: 5, outputLimit: 4).run(command("printf 'too much'"), directory: root, environment: [:])
        }
        #expect(throws: FarCmdsError.self) {
            try FarCmdsCaptureRunner(timeout: 0.04).run(command("/bin/sleep 2"), directory: root, environment: [:])
        }
        _ = try FarCmdsCaptureRunner(timeout: 5).run(command("(/bin/sleep 0.3; printf hit > marker)&"), directory: root, environment: [:])
        Thread.sleep(forTimeInterval: 0.4)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
    }

    @Test func fileInputAndSearchOrder() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("farhome"), path = root.appendingPathComponent("path")
        for directory in [home, path] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        let environment = ["FARHOME": home.path, "PATH": path.path, "PATHEXT": ".bin;.tool", "name": "Пример"]
        let homeFile = home.appendingPathComponent("tool.bin")
        let pathFile = path.appendingPathComponent("tool")
        try Data().write(to: homeFile)
        try Data().write(to: pathFile)
        #expect(FarCmdsFiles.search("tool", from: root, environment: environment)?.path == pathFile.path)
        try FileManager.default.removeItem(at: pathFile)
        #expect(FarCmdsFiles.search("tool", from: root, environment: environment)?.path == homeFile.path)
        let file = root.appendingPathComponent("path.txt")
        try Data("\"%NAME%/file\"\r\nignored".utf8).write(to: file)
        #expect(try FarCmdsFiles.path(in: file, maximumBytes: 128, environment: environment) == "Пример/file")
        #expect(try FarCmdsFiles.read(file, maximumBytes: 4) == Data("\"%NA".utf8))
        #expect(FarCmdsFiles.text(Data([65, 0, 66])) == "A")
        #expect(FarCmdsFiles.text(Data([0xff, 0xfe, 0x16, 0x04, 0, 0, 0x17, 0x04])) == "Ж")
    }

    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FarCmdsTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
