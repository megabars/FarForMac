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
    @Test(arguments: [false, true])
    func invocationOwnsInheritedHelpersAfterSuccessTimeoutAndCancellation(closesOutput: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExtensionChildren-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Pass the path as an argv value; no shell interpolation of fixture paths.
        // Closing stdout/stderr must not let a process escape group ownership.
        let helperOutput = closesOutput ? " >/dev/null 2>&1" : ""
        let helper = "(i=0; while [ \"$i\" -lt 100 ]; do printf x >> \"$1\"; i=$((i+1)); sleep 0.03; done)" + helperOutput + " & "
        let response = "printf '%s' '{\"apiVersion\":1,\"kind\":\"command\",\"title\":\"Done\",\"text\":\"OK\",\"rows\":[]}'"
        for ending in ["success", "timeout", "cancel", "oversize", "malformed"] {
            let marker = directory.appendingPathComponent("orphan-" + ending)
            let token = ExtensionCancellation()
            let body: String
            switch ending {
            case "success": body = response
            case "oversize": body = "while :; do printf 1234567890; done"
            case "malformed": body = "printf invalid"
            default: body = "sleep 5"
            }
            let awaitHelper = "while [ ! -s \"$1\" ]; do sleep 0.005; done; "
            let descriptor = ExtensionDescriptor(id: "children", title: "Children", kind: .command,
                executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", helper + awaitHelper + body, "extension-test", marker.path])
            if ending == "cancel" {
                DispatchQueue.global().async {
                    let deadline = ProcessInfo.processInfo.systemUptime + 5
                    while ((try? Data(contentsOf: marker))?.isEmpty ?? true), ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    token.cancel()
                }
            }
            do {
                let timeout: TimeInterval = ending == "timeout" ? 0.12 : (ending == "cancel" ? 10 : 3)
                let invocation = try ExtensionHost(timeout: timeout, maximumBytes: 1024).invoke(descriptor, request: ExtensionRequest(kind: .command), cancellation: token)
                #expect(ending == "success")
                #expect(invocation.response.text == "OK")
            } catch {
                #expect(ending != "success")
                let expectedErrors = ["cancel": "Extension cancelled.", "timeout": "Extension timed out.",
                                      "oversize": "Extension output exceeds the byte limit.", "malformed": "Malformed extension response JSON."]
                if let expected = expectedErrors[ending] { #expect(error.localizedDescription == expected) }
            }
            let before = (try? Data(contentsOf: marker)) ?? Data()
            if ending == "cancel" { #expect(!before.isEmpty, "Cancellation must exercise an already running helper") }
            Thread.sleep(forTimeInterval: 0.15)
            let after = (try? Data(contentsOf: marker)) ?? Data()
            #expect(after == before, "Inherited helper kept writing after \(ending)")
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
        func transform(_ mode: String, _ text: String, options: ExtensionTextOptions? = nil) throws -> String? {
            try ExtensionHost(timeout: 30).invoke(ExtensionDescriptor(id: mode, title: mode, kind: .editor,
                executableURL: python, arguments: [script.path, mode]), request: ExtensionRequest(kind: .editor, text: text, options: options)).response.text
        }
        #expect(try transform("editcase-upper", "Hello éß Я\r\n") == "HELLO ÉSS Я\r\n")
        #expect(try transform("editcase-lower", "HELLO Éẞ Я\n") == "hello éß я\n")
        #expect(try transform("editcase-title", "hELLO ЯЗЫК foo_bar#ßeta\r\n") == "Hello Язык Foo_bar#SSeta\r\n")
        #expect(try transform("editcase-toggle", "Hello Éẞ Яя ß") == "hELLO éß яЯ SS")
        for (before, after) in [("hello world", "HELLO WORLD"), ("HELLO WORLD", "Hello World"),
                                ("Hello World", "hello world"), ("A", "a"), ("a", "A"),
                                ("hELLO", "Hello"), ("heLLo", "hello"), ("привет мир", "ПРИВЕТ МИР"),
                                (" # ", " # ")] {
            #expect(try transform("editcase-cyclic", before) == after)
        }
        #expect(try transform("align", "  one two\r\n    three four five\r\n", options: .init(rightMargin: 15)) == "  one two three\r\n  four five\r\n")
        #expect(try transform("align", "one\n\n two", options: .init(rightMargin: 8)) == "one two")
        #expect(try transform("align", "abcdefg hijklm nopq", options: .init(rightMargin: 4)) == "abcdefg\nhijklm\nnopq")
        #expect(try transform("align", "привет мир снова", options: .init(rightMargin: 10)) == "привет мир\nснова")
        let smartText = "abcdefghijklmnopqrstu longer a nextword end"
        #expect(try transform("align", smartText, options: .init(rightMargin: 31)) == "abcdefghijklmnopqrstu longer a\nnextword end")
        #expect(try transform("align", smartText, options: .init(rightMargin: 31, smartMode: true)) == "abcdefghijklmnopqrstu longer\na nextword end")
        #expect(try transform("align", "a  b c\r\nx y\n", options: .init(rightMargin: 10, reformat: false, justify: true)) == "a    b   c\r\nx        y\n")
        #expect(try transform("align", "one two three four", options: .init(rightMargin: 10, justify: true)) == "one    two\nthree four")
        #expect(try transform("align", "\tone two", options: .init(rightMargin: 16)) == "        one two")
        #expect(try transform("align", "\tone two", options: .init(rightMargin: 16, tabSize: 2)) == "  one two")
        #expect(try transform("align", "\tone two\r", options: .init(rightMargin: 5, reformat: false)) == "\tone two\r")
        #expect(throws: (any Error).self) { try transform("align", "a b", options: .init(rightMargin: 0)) }
    }

    @Test func editorSnapshots() throws {
        let original = "😀 first слово tail\r\nsecond line\r\nlast"
        let source = original as NSString
        let word = source.range(of: "слово")
        let selected = try ExtensionEditorSnapshot(text: original, selection: word, scope: .selectionOrWord)
        #expect(selected.text == "слово")
        #expect(try selected.replacing(with: "СЛОВО", currentText: original) == "😀 first СЛОВО tail\r\nsecond line\r\nlast")
        #expect(throws: (any Error).self) { try selected.replacing(with: "X", currentText: original + "!") }
        let cursor = try ExtensionEditorSnapshot(text: original, selection: NSRange(location: word.location + 2, length: 0), scope: .selectionOrWord)
        #expect(cursor.range == word)
        let nearest = try ExtensionEditorSnapshot(text: "left   right", selection: NSRange(location: 5, length: 0), scope: .selectionOrWord)
        #expect(nearest.text == "left")
        let right = try ExtensionEditorSnapshot(text: "left   right", selection: NSRange(location: 6, length: 0), scope: .selectionOrWord)
        #expect(right.text == "right")
        let second = source.range(of: "second")
        let block = try ExtensionEditorSnapshot(text: original, selection: NSRange(location: word.location, length: second.location - word.location), scope: .selectedLines)
        #expect(block.text == "😀 first слово tail\r\n")
        #expect(try block.replacing(with: "new\r\n", currentText: original) == "new\r\nsecond line\r\nlast")
        #expect(throws: (any Error).self) { try ExtensionEditorSnapshot(text: original, selection: NSRange(location: 0, length: 0), scope: .selectedLines) }
        #expect(throws: (any Error).self) { try ExtensionEditorSnapshot(text: original, selection: NSRange(location: NSNotFound, length: 1), scope: .document) }
        #expect(throws: (any Error).self) { try ExtensionEditorSnapshot(text: original, selection: NSRange(location: 1, length: 0), scope: .selectionOrWord) }
        let empty = try ExtensionEditorSnapshot(text: " # \nword", selection: NSRange(location: 1, length: 0), scope: .selectionOrWord)
        #expect(empty.text.isEmpty)
        let end = try ExtensionEditorSnapshot(text: "слово", selection: NSRange(location: 5, length: 0), scope: .selectionOrWord)
        #expect(end.text == "слово")
    }

    @Test func versionOneOptionsAreOptional() throws {
        let data = Data(#"{"apiVersion":1,"kind":"editor","text":"abc","entries":[]}"#.utf8)
        #expect(try JSONDecoder().decode(ExtensionRequest.self, from: data).options == nil)
        let request = ExtensionRequest(kind: .editor, text: "x", options: .init(rightMargin: 42, smartMode: true))
        #expect(try JSONDecoder().decode(ExtensionRequest.self, from: JSONEncoder().encode(request)).options == request.options)
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
