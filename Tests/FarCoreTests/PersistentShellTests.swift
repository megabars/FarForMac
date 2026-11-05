import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite(.serialized)
struct PersistentShellTests {
    @Test func stateFramesAreBoundedSessionSpecificAndFragmentSafe() throws {
        let bridge = try PersistentShellIntegration()
        defer { bridge.cleanup() }
        let path = "/tmp/a ; ' Юникод\nfolder"
        let frame = "\u{1b}]777;farformac;\(bridge.token);ready;17;\(Data(path.utf8).base64EncodedString())\u{7}"
        var states: [PersistentShellIntegration.State] = []
        for byte in frame.utf8 { states += bridge.consume(Data([byte])) }
        #expect(states.count == 1)
        #expect(states.first?.ready == true)
        #expect(states.first?.exitCode == 17)
        #expect(states.first?.clearedDraft == false)
        #expect(states.first?.directory?.path == path)
        #expect(bridge.consume(Data(frame.replacingOccurrences(of: bridge.token, with: "other-session").utf8)).isEmpty)
        #expect(bridge.consume(Data(("\u{1b}]" + String(repeating: "x", count: 20_000) + "\u{7}").utf8)).isEmpty)
        #expect(bridge.consume(Data("\u{1b}]777;farformac;\(bridge.token);busy\u{1b}\\".utf8)).first?.ready == false)
        let continuation = bridge.consume(Data("\u{1b}]777;farformac;\(bridge.token);continuation\u{7}".utf8)).first
        #expect(continuation?.continuation == true)
        #expect(continuation?.ready == false)
        #expect(bridge.consume(Data(frame.utf8)).count == 1)
        #expect(bridge.consume(Data(frame.replacingOccurrences(of: ";ready;", with: ";cleared;").utf8)).first?.clearedDraft == true)
        #expect(throws: (any Error).self) { try PersistentShellIntegration.submission("bad\0command") }
        #expect(throws: (any Error).self) { try PersistentShellIntegration.submission(String(repeating: "x", count: 65_537)) }
    }

    @Test func variablesFunctionsAliasesAndDirectorySurviveCommands() throws {
        let fixture = try ManagedShellFixture()
        defer { fixture.stop() }
        let folder = fixture.root.appendingPathComponent("space ' Юникод")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try fixture.start()
        #expect(fixture.waitReady(1))
        try fixture.submit("export FAR_TEST_VALUE='retained value'; function far_test_function() { printf 'FUNCTION:%s\\n' \"$FAR_TEST_VALUE\"; }; alias far_test_alias='printf ALIAS_OK'; cd -- " + ShellCommand.quoteArgument(folder.path))
        #expect(fixture.waitReady(2))
        #expect(fixture.latest?.directory?.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        try fixture.submit("far_test_function; far_test_alias; printf '\\nDIRECTORY:%s\\n' \"$PWD\"; false")
        #expect(fixture.waitReady(3))
        #expect(fixture.latest?.exitCode == 1)
        #expect(fixture.output.contains("FUNCTION:retained value"))
        #expect(fixture.output.contains("ALIAS_OK"))
        #expect(fixture.output.contains("DIRECTORY:" + folder.path))
        try fixture.submit("printf 'MULTILINE_A\\n'\nprintf 'MULTILINE_B\\n'")
        #expect(fixture.waitReady(4))
        #expect(fixture.output.contains("MULTILINE_A\r\nMULTILINE_B"))
        try fixture.submit("exit 0")
        #expect(fixture.waitExit())
        #expect(fixture.exit?.succeeded == true)
    }

    @Test func commandBarCannotWriteIntoForegroundProgramAndInterruptRecovers() throws {
        let fixture = try ManagedShellFixture()
        defer { fixture.stop() }
        try fixture.start()
        #expect(fixture.waitReady(1))
        try fixture.submit("/bin/sleep 30")
        #expect(fixture.waitBusy())
        Thread.sleep(forTimeInterval: 0.15)
        #expect(throws: (any Error).self) { try fixture.submit("printf SHOULD_NOT_RUN") }
        try fixture.session.interrupt()
        #expect(fixture.waitReady(2))
        try fixture.submit("printf 'RECOVERED\\n'")
        #expect(fixture.waitReady(3))
        #expect(fixture.output.contains("RECOVERED"))
        #expect(!fixture.output.contains("SHOULD_NOT_RUN"))
    }

    @Test func readinessWaitsForLineEditorAndQueuedAbortClearsDraft() throws {
        let fixture = try ManagedShellFixture()
        defer { fixture.stop() }
        try fixture.start()
        #expect(fixture.waitReady(1))
        try fixture.session.send("printf partial")
        try fixture.session.send(PersistentShellIntegration.clearDraftInput)
        #expect(fixture.waitReady(2))
        try fixture.submit("printf 'AFTER_%s_OK\\n' ABORT")
        #expect(fixture.waitReady(3))
        #expect(fixture.output.contains("AFTER_ABORT_OK\r\n"))
        #expect(fixture.latest?.exitCode == 0)
        #expect(!fixture.output.contains("partialprintf"))
        try fixture.submit("vared -c FAR_INPUT_FIXTURE")
        #expect(fixture.waitBusy())
        Thread.sleep(forTimeInterval: 0.1)
        #expect(fixture.latest?.ready == false)
        try fixture.session.send("fixture answer\r")
        #expect(fixture.waitReady(4))
    }

    @Test func foregroundOnlyInterruptPreservesDraftAndReachesPipelineAfterLeaderExit() throws {
        let fixture = try ManagedShellFixture()
        defer { fixture.stop() }
        try fixture.start()
        try #require(fixture.waitReady(1))
        try fixture.session.send("printf 'QUEUED_%s\\n' DRAFT")
        #expect(try fixture.session.interruptForeground(allowShell: false) == nil)
        try fixture.session.send("\r")
        try #require(fixture.waitReady(2))
        #expect(fixture.output.contains("QUEUED_DRAFT\r\n"))

        try fixture.submit("/usr/bin/true | /bin/sh -c 'printf \"PIPELINE_%s\\n\" RUNNING; exec /bin/sleep 30'")
        try #require(fixture.waitOutput("PIPELINE_RUNNING\r\n"))
        let group = try #require(fixture.session.foregroundProcessGroup)
        try #require(group != fixture.session.processID)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while getsid(group) != -1 && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        try #require(getsid(group) == -1)
        #expect(try fixture.session.interruptForeground(allowShell: false) == .job)
        #expect(fixture.waitReady(3))
    }

    @Test func privateStartupFilesAreRemovedAndDoNotUseUserHistory() throws {
        let bridge = try PersistentShellIntegration()
        let directory = bridge.directory
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let script = directory.appendingPathComponent(".zshrc")
        #expect((try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try String(contentsOf: script, encoding: .utf8).contains("unset HISTFILE"))
        bridge.cleanup()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

private final class ManagedShellFixture: @unchecked Sendable {
    let root: URL
    let bridge: PersistentShellIntegration
    private let lock = NSCondition()
    private var bytes = Data()
    private var states: [PersistentShellIntegration.State] = []
    private var result: TerminalSession.Exit?
    lazy var session = TerminalSession(configuration: bridge.configuration(directory: root, columns: 100, rows: 24),
        callbackQueue: DispatchQueue(label: "PersistentShellTests.callbacks"), onOutput: { [weak self] data in
            guard let self else { return }
            self.lock.lock(); self.bytes.append(data); self.states += self.bridge.consume(data)
            self.lock.broadcast(); self.lock.unlock()
        }, onExit: { [weak self] exit in
            guard let self else { return }
            self.lock.lock(); self.result = exit; self.lock.broadcast(); self.lock.unlock()
        })
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        bridge = try PersistentShellIntegration()
    }
    func start() throws { try session.start() }
    func submit(_ command: String) throws { try session.sendToForegroundShell(PersistentShellIntegration.submission(command)) }
    var latest: PersistentShellIntegration.State? { lock.lock(); defer { lock.unlock() }; return states.last }
    var output: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    var exit: TerminalSession.Exit? { lock.lock(); defer { lock.unlock() }; return result }
    func waitReady(_ count: Int) -> Bool { wait { self.states.filter(\.ready).count >= count } }
    func waitBusy() -> Bool { wait { self.states.last?.ready == false } }
    func waitOutput(_ text: String) -> Bool { wait { String(decoding: self.bytes, as: UTF8.self).contains(text) } }
    func waitExit() -> Bool { wait { self.result != nil } }
    private func wait(_ predicate: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(8)
        while !predicate() { if !lock.wait(until: deadline) { return predicate() } }
        return true
    }
    func stop() {
        session.forceStop(); _ = waitExit(); bridge.cleanup(); try? FileManager.default.removeItem(at: root)
    }
}
