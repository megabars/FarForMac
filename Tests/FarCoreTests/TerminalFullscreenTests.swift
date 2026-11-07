import Foundation
import Testing
@testable import FarCore

@Suite(.serialized) struct TerminalFullscreenTests {
    @Test func systemVimAcceptsFunctionKeysMouseAndResizeAndReturnsToPrimary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("document.txt")
        try "START\nshift row\nmouse row\nresize row\nclick here\n".write(to: file, atomically: true, encoding: .utf8)
        let vimrc = directory.appendingPathComponent("test.vim")
        try #"""
        set ttymouse=sgr mouse=a timeoutlen=150 ttimeoutlen=150
        function! Clicked()
            call setline(3, printf('CLICKED:%d:%d', line('.'), col('.')))
        endfunction
        nnoremap <silent> <F5> :call setline(1, 'FIVE_KEY')<CR>
        nnoremap <silent> <S-F6> :call setline(2, 'SHIFT_SIX')<CR>
        nnoremap <silent> <LeftMouse> <LeftMouse>:call Clicked()<CR>
        autocmd VimResized * call setline(4, printf('RESIZED:%dx%d', &columns, &lines))
        """#.write(to: vimrc, atomically: true, encoding: .utf8)
        let capture = TerminalFullscreenCapture(columns: 56, rows: 12)
        let command = #"printf 'PRIMARY-PROMPT\n'; /usr/bin/vim -N -u test.vim -U NONE -i NONE -n document.txt; result=$?; printf '\nVIM_EXIT:%s\n' "$result"; exit "$result""#
        let session = capture.session(command: command, directory: directory)
        try session.start()
        defer { session.forceStop() }
        let initial = try #require(capture.waitForScreen {
            $0.isAlternateScreen && $0.plainText.contains("START") && $0.mouseReporting.encoding == .sgr
        })
        #expect(!initial.plainText.contains("PRIMARY-PROMPT"))
        try session.send(TerminalInput.encode(.function(5)))
        try session.send(TerminalInput.encode(.function(6), modifiers: [.shift]))
        #expect(capture.waitForScreen { $0.lines.prefix(2) == ["FIVE_KEY", "SHIFT_SIX"] } != nil)

        let press = try #require(initial.mouseReporting.encode(.press(.left), column: 3, row: 5))
        let release = try #require(initial.mouseReporting.encode(.release(.left), column: 3, row: 5))
        try session.send(press + release)
        #expect(capture.waitForScreen { $0.plainText.contains("CLICKED:5:3") } != nil)

        try capture.resize(session, columns: 72, rows: 16)
        #expect(capture.waitForScreen { $0.isAlternateScreen && $0.plainText.contains("RESIZED:72x16") } != nil)
        try session.send(":qa!\r")
        #expect(capture.waitForExit()?.code == 0)
        let final = try #require(capture.waitForScreen { !$0.isAlternateScreen && $0.plainText.contains("VIM_EXIT:0") })
        #expect(final.plainText.contains("PRIMARY-PROMPT"))
        #expect(!final.plainText.contains("FIVE_KEY"))
    }

    @Test func systemLessPagesThroughPTYAndRestoresPrimary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = (1...60).map { "pager-\($0)" }.joined(separator: "\n") + "\n"
        try contents.write(to: directory.appendingPathComponent("pager.txt"), atomically: true, encoding: .utf8)
        let capture = TerminalFullscreenCapture(columns: 40, rows: 8)
        let session = capture.session(command: #"printf 'BEFORE-PAGER\n'; unset LESS LESSOPEN LESSCLOSE; /usr/bin/less pager.txt; printf '\nAFTER-PAGER\n'"#,
                                      directory: directory)
        try session.start()
        defer { session.forceStop() }
        #expect(capture.waitForScreen { $0.isAlternateScreen && $0.lines.first == "pager-1" } != nil)
        try session.send(TerminalInput.encode(.pageDown))
        #expect(capture.waitForScreen { $0.isAlternateScreen && $0.lines.first == "pager-8" } != nil)
        try session.send(TerminalInput.encode(.pageUp))
        #expect(capture.waitForScreen { $0.isAlternateScreen && $0.lines.first == "pager-1" } != nil)
        try session.send("q")
        #expect(capture.waitForExit()?.code == 0)
        let final = try #require(capture.waitForScreen { !$0.isAlternateScreen && $0.plainText.contains("AFTER-PAGER") })
        #expect(final.plainText.contains("BEFORE-PAGER"))
        #expect(!final.plainText.contains("pager-1"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-fullscreen-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class TerminalFullscreenCapture: @unchecked Sendable {
    private let condition = NSCondition()
    private var screen: TerminalScreen
    private var exit: TerminalSession.Exit?
    private weak var running: TerminalSession?

    init(columns: Int, rows: Int) { screen = TerminalScreen(columns: columns, rows: rows) }

    func session(command: String, directory: URL) -> TerminalSession {
        let session = TerminalSession(
            configuration: .init(command: command, directory: directory, shell: "/bin/zsh", columns: screen.columns, rows: screen.rows,
                                 shellArguments: ["-f", "-i", "-c", command],
                                 environmentOverrides: ["TERM": "xterm-256color", "COLORTERM": "truecolor", "LC_ALL": "en_US.UTF-8"]),
            callbackQueue: DispatchQueue(label: "TerminalFullscreenTests.callbacks"),
            onOutput: { [self] bytes in
                let (session, replies) = condition.withLock {
                    screen.append(bytes)
                    condition.broadcast()
                    return (running, screen.takeResponses())
                }
                if !replies.isEmpty { try? session?.send(replies) }
            },
            onExit: { [self] result in
                condition.withLock {
                    screen.finishProcess()
                    exit = result
                    condition.broadcast()
                }
            }
        )
        condition.withLock { running = session }
        return session
    }

    func resize(_ session: TerminalSession, columns: Int, rows: Int) throws {
        condition.withLock { screen.resize(columns: columns, rows: rows) }
        try session.resize(columns: columns, rows: rows)
    }

    func waitForScreen(_ condition: (TerminalScreen) -> Bool) -> TerminalScreen? {
        wait { condition(screen) ? screen : nil }
    }

    func waitForExit() -> TerminalSession.Exit? { wait { exit } }

    private func wait<T>(_ snapshot: () -> T?) -> T? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(8)
        if let result = snapshot() { return result }
        while exit == nil && condition.wait(until: deadline) {
            if let result = snapshot() { return result }
        }
        return snapshot()
    }
}
