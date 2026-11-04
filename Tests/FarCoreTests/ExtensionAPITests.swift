import Foundation
import Testing
@testable import FarCore

@Suite struct ExtensionAPITests {
    private func run(_ script: String, version: Int = 1, timeout: TimeInterval = 1, limit: Int = 8192) throws -> ExtensionInvocation {
        let descriptor = ExtensionDescriptor(id: "test", title: "Test", apiVersion: version, kind: .command,
                                             executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        return try ExtensionHost(timeout: timeout, maximumBytes: limit).invoke(descriptor, request: ExtensionRequest(kind: .command))
    }
    @Test func responseAndLifecycle() throws {
        let result = try run("printf '%s' '{\"apiVersion\":1,\"kind\":\"command\",\"title\":\"Hello\",\"text\":\"World\",\"rows\":[]}'")
        #expect(result.response.text == "World")
        #expect(result.lifecycle == [.starting, .running, .finished])
    }
    @Test func rejectsFaults() {
        for script in ["printf garbage", "exit 4", "kill -KILL $$",
                       "printf '%s' '{\"apiVersion\":2,\"kind\":\"command\",\"title\":\"X\",\"text\":\"X\",\"rows\":[]}'",
                       "printf '%s' '{\"apiVersion\":1,\"kind\":\"panel\",\"title\":\"X\",\"rows\":[]}'"] {
            #expect(throws: (any Error).self) { try run(script) }
        }
        #expect(throws: (any Error).self) { try run("exit 0", version: 2) }
        do {
            _ = try run("sleep 2", timeout: 0.05)
            Issue.record("Expected the extension execution deadline to reject a slow process")
        } catch {
            #expect(error.localizedDescription == "Extension timed out.")
        }
        #expect(throws: (any Error).self) { try run("while :; do printf 1234567890; done", limit: 128) }
    }
    @Test func cancellation() throws {
        let cancellation = ExtensionCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { cancellation.cancel() }
        let descriptor = ExtensionDescriptor(id: "cancel", title: "Cancel", kind: .command,
                                            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"])
        #expect(throws: (any Error).self) {
            try ExtensionHost().invoke(descriptor, request: ExtensionRequest(kind: .command), cancellation: cancellation)
        }
    }
    @Test func bundledExamples() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Examples/Extensions/text-tools.py")
        let python = try selectedPython()
        let cases: [(String, ExtensionKind, String?)] = [("checksum", .command, "abc"), ("stats", .panel, nil),
                                                       ("json", .viewer, "{\"b\":1}"), ("uppercase", .editor, "Hello")]
        for (mode, kind, text) in cases {
            let descriptor = ExtensionDescriptor(id: mode, title: mode, kind: kind, executableURL: python, arguments: [script.path, mode])
            let result = try ExtensionHost(timeout: 30).invoke(descriptor, request: ExtensionRequest(kind: kind, text: text,
                entries: [ExtensionEntry(name: "a", isDirectory: false, size: 42)]))
            switch kind {
            case .command: #expect(result.response.text == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            case .panel: #expect(result.response.rows.last?.value == "42")
            case .viewer: #expect(result.response.text?.contains("\"b\": 1") == true)
            case .editor: #expect(result.response.text == "HELLO")
            }
        }
    }
    @Test func farBehaviorPorts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Examples/Extensions/text-tools.py")
        let python = try selectedPython()
        func transform(_ mode: String, _ text: String) throws -> String? {
            try ExtensionHost(timeout: 30).invoke(ExtensionDescriptor(id: mode, title: mode, kind: .editor,
                executableURL: python, arguments: [script.path, mode]), request: ExtensionRequest(kind: .editor, text: text)).response.text
        }
        #expect(try transform("editcase-upper", "Hello éß Я\r\n") == "HELLO éß Я\r\n")
        #expect(try transform("editcase-lower", "HELLO Éẞ Я\n") == "hello Éẞ Я\n")
        #expect(try transform("align", "a b c\r\nx y\n") == "a" + String(repeating: " ", count: 36) + "b" + String(repeating: " ", count: 36) + "c\r\nx" + String(repeating: " ", count: 73) + "y\n")
        #expect(try transform("align", "ab c d") == "ab" + String(repeating: " ", count: 36) + "c" + String(repeating: " ", count: 35) + "d")
        for unchanged in ["one", " a b", "a b ", "a  b", "a\tb", "é a", String(repeating: "a", count: 73) + " b"] {
            #expect(try transform("align", unchanged) == unchanged)
        }
    }

    // These integration cases verify the example protocol and behavior with the
    // selected Python. The host deliberately sanitizes PATH, so executing the
    // script's env shebang would silently select Apple's developer-tools shim.
    // Interpreter startup under shared CI load gets a bounded 30-second budget;
    // the separate slow-process test still verifies the real execution deadline.
    private func selectedPython() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let python = environment["FAR_TEST_PYTHON"] ?? "python3"
        let candidates: [URL]
        if python.contains("/") {
            candidates = [URL(fileURLWithPath: python).standardizedFileURL]
        } else {
            candidates = (environment["PATH"] ?? "/usr/bin:/bin")
                .split(separator: ":", omittingEmptySubsequences: false)
                .map { URL(fileURLWithPath: $0.isEmpty ? "." : String($0)).appendingPathComponent(python) }
        }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw NSError(domain: "ExtensionAPITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Python interpreter not found: \(python). Select python3 on PATH or set FAR_TEST_PYTHON."
            ])
        }
        return executable
    }

}
