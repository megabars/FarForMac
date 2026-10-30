import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite(.serialized)
struct TerminalSessionTests {
    @Test func commandHasControllingPTYExplicitDirectoryAndUTF8() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terminal space ' Юникод \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = TerminalCapture()
        let command = #"test -t 0 && test -t 1 && test -t 2 && : </dev/tty && printf 'TRUE_PTY\n'; printf '%s\n' "$PWD"; printf 'Привет🙂\n'; printf 'TERM=%s COLOR=%s\n' "$TERM" "${COLORTERM-unset}"; /bin/stty size; exit 7"#
        let session = capture.session(command: command, directory: directory, columns: 93, rows: 27)
        try session.start()
        #expect(capture.waitForExit())
        #expect(capture.output.contains("TRUE_PTY"))
        #expect(capture.output.contains(directory.path))
        #expect(capture.output.contains("Привет🙂"))
        #expect(capture.output.contains("27 93"))
        #expect(capture.output.contains("TERM=vt100 COLOR=unset"))
        #expect(capture.exit?.code == 7)
        #expect(!session.isRunning)
    }

    @Test func interactiveInputAndWindowResizeReachChild() throws {
        let capture = TerminalCapture()
        let session = capture.session(command: #"printf 'READY\n'; read answer; /bin/stty size; printf 'ANSWER:%s\n' "$answer""#)
        try session.start()
        defer { session.stop() }
        #expect(capture.waitForOutput("READY"))
        try session.resize(columns: 71, rows: 19)
        try session.send("Привет input\n")
        #expect(capture.waitForExit())
        #expect(capture.output.contains("19 71"))
        #expect(capture.output.contains("ANSWER:Привет input"))
    }

    @Test func interruptTargetsForegroundJobAndStopReapsSession() throws {
        let capture = TerminalCapture()
        let session = capture.session(command: #"printf 'READY\n'; /bin/sleep 30; printf 'AFTER\n'"#)
        try session.start()
        defer { session.stop() }
        #expect(capture.waitForOutput("READY"))
        // Wait until the shell has transferred the foreground process group.
        Thread.sleep(forTimeInterval: 0.15)
        try session.interrupt()
        #expect(capture.waitForExit())
        #expect(!session.isRunning)
        #expect(capture.exit != nil)

        let stopped = TerminalCapture()
        let second = stopped.session(command: #"trap '' HUP TERM; printf 'STOP_READY\n'; while :; do /bin/sleep 1; done"#)
        try second.start()
        #expect(stopped.waitForOutput("STOP_READY"))
        let child = try #require(second.processID)
        second.stop()
        #expect(stopped.waitForExit())
        #expect(!second.isRunning)
        #expect(kill(child, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func stoppingAlsoTerminatesBackgroundJobsAndDisposalReaps() throws {
        let capture = TerminalCapture()
        let session = capture.session(command: #"trap '' HUP TERM; /bin/sleep 30 & bg=$!; printf 'BG:%s\n' "$bg"; while :; do /bin/sleep 1; done"#)
        try session.start()
        defer { session.stop() }
        #expect(capture.waitForOutput("BG:"))
        let line = try #require(capture.output.components(separatedBy: .newlines).first { $0.hasPrefix("BG:") })
        let background = try #require(Int32(line.dropFirst(3)))
        session.stop()
        #expect(capture.waitForExit())
        let deadline = Date().addingTimeInterval(2)
        while kill(background, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(kill(background, 0) == -1)

        let disposed = TerminalCapture()
        var temporary: TerminalSession? = disposed.session(command: #"printf 'DISPOSE_READY\n'; /bin/sleep 30"#)
        try temporary?.start()
        #expect(disposed.waitForOutput("DISPOSE_READY"))
        let child = try #require(temporary?.processID)
        temporary = nil
        let disposalDeadline = Date().addingTimeInterval(2)
        while kill(child, 0) == 0 && Date() < disposalDeadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(kill(child, 0) == -1)
    }

    @Test func immediateShutdownKillsWithoutWaitingForEscalation() throws {
        let capture = TerminalCapture()
        let session = capture.session(command: #"trap '' HUP TERM; printf 'FORCE_READY\n'; while :; do /bin/sleep 1; done"#)
        try session.start()
        defer { session.forceStop() }
        #expect(capture.waitForOutput("FORCE_READY"))
        session.forceStop()
        #expect(capture.waitForExit())
        #expect(capture.exit?.signal == SIGKILL)
        #expect(!session.isRunning)
    }

    @Test func outputIsDrainedBeforeExitAndBackpressureBoundsCallbacks() throws {
        let callbacks = DispatchQueue(label: "TerminalTest.slowCallbacks")
        let capture = TerminalCapture()
        callbacks.suspend()
        let session = capture.session(command: #"/usr/bin/yes 1234567890 | /usr/bin/head -c 350000; printf '\nFINAL_MARKER\n'"#, callbackQueue: callbacks)
        do { try session.start() }
        catch { callbacks.resume(); throw error }
        // With callback consumption blocked, the producer must block in its PTY
        // rather than enqueueing the entire stream into application memory.
        Thread.sleep(forTimeInterval: 0.2)
        #expect(session.isRunning)
        #expect(capture.byteCount == 0)
        callbacks.resume()
        #expect(capture.waitForExit())
        #expect(capture.output.contains("FINAL_MARKER"))
        #expect(capture.byteCount >= 350_000)
        #expect(capture.largestChunk <= 65_536)
        #expect(capture.outputAtExit == capture.byteCount)
    }

    @Test func launchFailuresAreReportedWithoutRunningChild() throws {
        let capture = TerminalCapture()
        let session = capture.session(command: "true", directory: URL(fileURLWithPath: "/nonexistent/FarTerminal/\(UUID().uuidString)"))
        #expect(throws: TerminalSession.SessionError.self) { try session.start() }
        #expect(!session.isRunning)
    }
}

private final class TerminalCapture: @unchecked Sendable {
    private let lock = NSCondition()
    private var bytes = Data()
    private var result: TerminalSession.Exit?
    private var chunkSize = 0
    private var atExit = 0
    var output: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    var exit: TerminalSession.Exit? { lock.withLock { result } }
    var byteCount: Int { lock.withLock { bytes.count } }
    var largestChunk: Int { lock.withLock { chunkSize } }
    var outputAtExit: Int { lock.withLock { atExit } }
    func session(command: String, directory: URL = FileManager.default.temporaryDirectory,
                 columns: Int = 100, rows: Int = 30,
                 callbackQueue: DispatchQueue = DispatchQueue(label: "TerminalTest.callbacks")) -> TerminalSession {
        TerminalSession(configuration: .init(command: command, directory: directory, shell: "/bin/zsh", columns: columns, rows: rows), callbackQueue: callbackQueue, onOutput: { [self] data in
            lock.lock(); bytes.append(data); chunkSize = max(chunkSize, data.count); lock.broadcast(); lock.unlock()
        }, onExit: { [self] exit in
            lock.lock(); result = exit; atExit = bytes.count; lock.broadcast(); lock.unlock()
        })
    }
    func waitForExit() -> Bool { wait { result != nil } }
    func waitForOutput(_ text: String) -> Bool { wait { String(decoding: bytes, as: UTF8.self).contains(text) } }
    private func wait(_ predicate: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(8)
        while !predicate() { if !lock.wait(until: deadline) { return predicate() } }
        return true
    }
}
