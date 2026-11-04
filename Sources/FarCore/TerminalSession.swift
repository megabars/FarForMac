import Foundation
import Darwin
import CFarPTY

/// An actual controlling-PTY session. Output is delivered in order with backpressure:
/// at most one 64 KiB output callback is pending, even when the UI is busy.
public final class TerminalSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var command: String?
        public var directory: URL
        public var shell: String?
        public var columns: Int
        public var rows: Int
        public var shellArguments: [String]?
        public var environmentOverrides: [String: String]

        public init(command: String? = nil, directory: URL, shell: String? = nil,
                    columns: Int = 100, rows: Int = 30, shellArguments: [String]? = nil,
                    environmentOverrides: [String: String] = [:]) {
            self.command = command
            self.directory = directory
            self.shell = shell
            self.columns = columns
            self.rows = rows
            self.shellArguments = shellArguments
            self.environmentOverrides = environmentOverrides
        }
    }

    public struct Exit: Equatable, Sendable {
        public let code: Int32?
        public let signal: Int32?
        public var succeeded: Bool { code == 0 }
    }

    public enum SessionError: Error, LocalizedError {
        case alreadyStarted, notRunning, inputBufferFull
        case system(String, Int32)
        public var errorDescription: String? {
            switch self {
            case .alreadyStarted: return "Эта терминальная сессия уже запущена."
            case .notRunning: return "Терминальная сессия уже завершена."
            case .inputBufferFull: return "Буфер ввода терминала заполнен. Дождитесь обработки данных."
            case let .system(operation, code): return "\(operation): \(String(cString: strerror(code)))"
            }
        }
    }

    private let configuration: Configuration
    private let callbackQueue: DispatchQueue
    private let onOutput: (Data) -> Void
    private let onExit: (Exit) -> Void
    private let queue = DispatchQueue(label: "FarCore.TerminalSession")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var started = false
    private var pid: pid_t?
    private var descriptor: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var outputPaused = false
    private var input = Data()
    private var childExit: Exit?
    private var stopping = false

    public init(configuration: Configuration, callbackQueue: DispatchQueue = .main,
                onOutput: @escaping (Data) -> Void, onExit: @escaping (Exit) -> Void) {
        self.configuration = configuration
        self.callbackQueue = callbackQueue
        self.onOutput = onOutput
        self.onExit = onExit
        queue.setSpecific(key: queueKey, value: 1)
    }

    public var isRunning: Bool { synchronized { pid != nil } }
    public var processID: Int32? { synchronized { pid } }

    public func start() throws {
        try synchronized {
            guard !started else { throw SessionError.alreadyStarted }
            var master: Int32 = -1
            var slave: Int32 = -1
            var size = Self.windowSize(columns: configuration.columns, rows: configuration.rows)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw error("openpty") }
            var ownedMaster = true
            defer { Darwin.close(slave); if ownedMaster { Darwin.close(master) } }
            guard fcntl(master, F_SETFD, FD_CLOEXEC) != -1,
                  fcntl(master, F_SETFL, O_NONBLOCK) != -1 else { throw error("fcntl") }

            let shell = configuration.shell ?? Self.userShell()
            guard !shell.utf8.contains(0), !(configuration.command?.utf8.contains(0) ?? false),
                  !configuration.directory.path.utf8.contains(0) else {
                throw SessionError.system("terminal arguments", EINVAL)
            }
            // Interactive mode enables shell job control for foreground programs.
            let arguments = configuration.shellArguments.map { [shell] + $0 }
                ?? configuration.command.map { [shell, "-i", "-c", $0] } ?? [shell, "-i"]
            guard arguments.allSatisfy({ !$0.utf8.contains(0) }),
                  configuration.environmentOverrides.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
                throw SessionError.system("terminal environment", EINVAL)
            }
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "vt100"
            environment.removeValue(forKey: "COLORTERM")
            environment["PWD"] = configuration.directory.path
            environment.merge(configuration.environmentOverrides) { _, new in new }
            let argv = arguments.map { strdup($0) }
            let envp = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") }
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else {
                throw SessionError.system("terminal arguments", ENOMEM)
            }
            var newPID: pid_t = 0
            let result = (argv + [nil]).withUnsafeBufferPointer { arguments in
                (envp + [nil]).withUnsafeBufferPointer { environment in
                    far_pty_fork_exec(master, slave, shell,
                                     UnsafeMutablePointer(mutating: arguments.baseAddress!),
                                     UnsafeMutablePointer(mutating: environment.baseAddress!),
                                     configuration.directory.path, &newPID)
                }
            }
            try check(result, "launch shell")
            started = true
            pid = newPID
            descriptor = master
            ownedMaster = false
            let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { Darwin.close(master) }
            reader = source
            source.resume()
            // Reap on this same queue so no delayed signal can target a reused PID.
            // The monitor retains itself until exit and also reaps after owner disposal.
            let child = newPID
            let monitor = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
            monitor.setEventHandler { [weak self] in
                // A per-command terminal owns its whole session, including jobs
                // which the shell left in the background when it exited.
                self?.signalGroups(child: child, signal: SIGKILL)
                var status: Int32 = 0
                var result: pid_t
                repeat { result = waitpid(child, &status, 0) } while result == -1 && errno == EINTR
                monitor.cancel()
                guard let self else { return }
                self.pid = nil
                self.childExit = Exit(code: status & 0x7f == 0 ? (status >> 8) & 0xff : nil,
                                      signal: status & 0x7f == 0 ? nil : status & 0x7f)
                if self.descriptor < 0 { self.finishIfExited() }
                else if !self.outputPaused { self.readAvailable() }
            }
            monitor.resume()
        }
    }

    public func send(_ text: String) throws { try send(Data(text.utf8)) }
    /// Command-bar submissions must never become input to a foreground program.
    public func sendToForegroundShell(_ text: String) throws {
        try synchronized {
            guard let child = pid, descriptor >= 0, tcgetpgrp(descriptor) == child else {
                throw SessionError.system("shell is not in foreground", EBUSY)
            }
            try send(text)
        }
    }
    public func send(_ data: Data) throws {
        try synchronized {
            guard pid != nil, descriptor >= 0, !stopping else { throw SessionError.notRunning }
            guard data.count <= 1_048_576 - input.count else { throw SessionError.inputBufferFull }
            input.append(data)
            writeAvailable()
        }
    }

    public func resize(columns: Int, rows: Int) throws {
        try synchronized {
            guard descriptor >= 0 else { throw SessionError.notRunning }
            var size = Self.windowSize(columns: columns, rows: rows)
            guard ioctl(descriptor, TIOCSWINSZ, &size) == 0 else { throw error("resize terminal") }
        }
    }

    /// Send SIGINT only to the PTY's current foreground process group.
    public func interrupt() throws {
        try synchronized {
            guard let child = pid, descriptor >= 0 else { throw SessionError.notRunning }
            let foreground = tcgetpgrp(descriptor)
            guard foreground > 1, foreground != getpgrp(), getsid(foreground) == child else {
                throw SessionError.system("terminal foreground process", ESRCH)
            }
            // A program may never read its stdin. Do not hand its queued text
            // to the shell after interruption (including our unwritten buffer).
            input.removeAll()
            writer?.cancel(); writer = nil
            guard tcflush(descriptor, TCIFLUSH) == 0 else { throw error("flush terminal input") }
            guard kill(-foreground, SIGINT) == 0 else { throw error("interrupt terminal") }
        }
    }

    /// End this isolated session, escalating after a short grace period.
    public func stop() {
        synchronized {
            guard let child = pid, !stopping else { return }
            stopping = true
            signalGroups(child: child, signal: SIGHUP)
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.pid == child else { return }
                self.signalGroups(child: child, signal: SIGKILL)
            }
        }
    }

    /// Immediate application-shutdown cleanup, without a delayed escalation.
    public func forceStop() {
        synchronized {
            guard let child = pid else { return }
            stopping = true
            signalGroups(child: child, signal: SIGKILL)
        }
    }

    private func signalGroups(child: pid_t, signal: Int32) {
        guard child > 1, child != getpgrp(), getsid(child) == child else { return }
        var groups: Set<pid_t> = [child]
        if descriptor >= 0 {
            let foreground = tcgetpgrp(descriptor)
            if foreground > 1 { groups.insert(foreground) }
        }
        // Interactive shells give each job its own process group. Enumerate only
        // this session, so background/stopped jobs also receive stop signals.
        var sessionGroups = [pid_t](repeating: 0, count: 16_384)
        let count = far_pty_session_groups(child, &sessionGroups, Int32(sessionGroups.count))
        if count > 0 { groups.formUnion(sessionGroups.prefix(Int(count))) }
        for group in groups where group != getpgrp() {
            // A group belongs to this session while its leader remains present.
            // The shell PID is reserved (not reaped) until this serial operation.
            if getsid(group) == child { _ = kill(-group, signal) }
        }
    }

    private func readAvailable() {
        guard descriptor >= 0, !outputPaused else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        var count: Int
        repeat { count = Darwin.read(descriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
        if count > 0 {
            let data = Data(bytes.prefix(count))
            outputPaused = true
            reader?.suspend()
            callbackQueue.async { [weak self, onOutput] in
                onOutput(data)
                self?.queue.async { [weak self] in
                    guard let self, self.outputPaused else { return }
                    self.outputPaused = false
                    self.reader?.resume()
                    if self.childExit != nil { self.readAvailable() }
                }
            }
        } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) || childExit != nil {
            closeTerminal()
            finishIfExited()
        }
    }

    private func writeAvailable() {
        guard descriptor >= 0 else { return }
        while !input.isEmpty {
            let count = input.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { input.removeFirst(count) }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                    source.setEventHandler { [weak self] in self?.writeAvailable() }
                    writer = source
                    source.resume()
                }
                return
            } else { input.removeAll(); break }
        }
        writer?.cancel()
        writer = nil
    }

    private func closeTerminal() {
        writer?.cancel()
        writer = nil
        if outputPaused { reader?.resume(); outputPaused = false }
        reader?.cancel()
        reader = nil
        descriptor = -1
        input.removeAll()
    }

    private func finishIfExited() {
        guard let exit = childExit else { return }
        childExit = nil
        callbackQueue.async { [onExit] in onExit(exit) }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    private func error(_ operation: String) -> SessionError { .system(operation, errno) }
    private func check(_ code: Int32, _ operation: String) throws {
        if code != 0 { throw SessionError.system(operation, code) }
    }
    private static func userShell() -> String {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let suggested = sysconf(_SC_GETPW_R_SIZE_MAX)
        var buffer = [CChar](repeating: 0, count: min(1_048_576, max(16_384, Int(suggested))))
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(getuid(), &entry, bytes.baseAddress, bytes.count, &result) == 0,
                  result != nil, let shell = entry.pw_shell, shell.pointee != 0 else { return "/bin/zsh" }
            return String(cString: shell)
        }
    }
    private static func windowSize(columns: Int, rows: Int) -> winsize {
        winsize(ws_row: UInt16(clamping: max(1, rows)), ws_col: UInt16(clamping: max(1, columns)),
                ws_xpixel: 0, ws_ypixel: 0)
    }
    deinit {
        synchronized {
            if let child = pid { signalGroups(child: child, signal: SIGKILL) }
            closeTerminal()
        }
    }
}
