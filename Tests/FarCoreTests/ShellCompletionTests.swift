import Foundation
import Testing
@testable import FarCore

@Suite
struct ShellCompletionTests {
    @Test func completionKeepsHistoryOrderAndQuotesPathsAndExecutableNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FarCompletion-" + UUID().uuidString)
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = bin.appendingPathComponent("python fake")
        try Data().write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        try Data().write(to: bin.appendingPathComponent("pythonNotExecutable"))
        try Data().write(to: directory.appendingPathComponent("python file.txt"))
        let result = try ShellCommand.completeLine("py", currentDirectory: directory, history: ["python history", "cd somewhere", "PYTHON HISTORY2"],
            environment: ["PATH": bin.path], manual: true)
        #expect(result.candidates.map(\.command) == ["python history", "PYTHON HISTORY2", "'./python file.txt'", "'python fake'"])
        #expect(result.candidates.map(\.source) == [.history, .history, .filesystem, .path])
        #expect(!result.isTruncated)
    }

    @Test func completionHandlesExplicitEnvironmentSyntaxAndSourceModes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Far Environment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("file with space"))
        var settings = ShellCompletionSettings()
        settings.sources = [.filesystem: .manualOnly, .environment: .manualOnly, .history: .disabled, .path: .disabled]
        let environment = ["FIXTURE": directory.path]
        for command in ["echo $FIX", "echo ${FIX", "cd %FIX", "cat ${FIXTURE}/fi"] {
            let automatic = try ShellCommand.completeLine(command, currentDirectory: directory, history: [command + "T"], environment: environment, settings: settings)
            #expect(automatic.candidates.isEmpty)
        }
        for (partial, expected) in [("echo $FIX", "echo $FIXTURE"), ("echo ${FIX", "echo ${FIXTURE}"),
                                    ("cd %FIX", "cd %FIXTURE%"), ("cat ${FIXTURE}/fi", #"cat "${FIXTURE}"/'file with space'"#)] {
            let result = try ShellCommand.completeLine(partial, currentDirectory: directory, history: [partial + "T"], environment: environment, settings: settings, manual: true)
            #expect(result.candidates.map(\.command) == [expected], "\(partial)")
        }
    }

    @Test func farPromptExpandsCodesPreservesColorAndFitsTheWidth() {
        let directory = URL(fileURLWithPath: "/folders/a-very-long-name", isDirectory: true)
        let prompt = ShellPrompt.render("%USER%$s$@()$s(F:1:bold)$p()$g$+$#25", directory: directory,
            environment: ["USER": "ivan"], stackDepth: 2, isAdministrator: true)
        #expect(prompt.maximumWidthPercent == 25)
        #expect(prompt.segments.map(\.text).joined() == "ivan (Administrator) /folders/a-very-long-name>++")
        let path = prompt.segments.first { $0.text == directory.path }
        #expect(path?.style.foreground == .indexed(15))
        #expect(path?.style.background == .indexed(4))
        #expect(path?.style.styles == ["bold"])
        let fitted = prompt.fitted(to: 112).map(\.text).joined()
        #expect(fitted.hasSuffix(">++"))
        #expect(fitted.count <= 28)
        let escaping = ShellPrompt.render("$C$a$b$f$l$q$$$H$g", directory: directory)
        #expect(escaping.segments.map(\.text).joined() == "(&|)<=>")
    }
}
