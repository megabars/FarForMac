import Foundation
import Darwin

public enum ExtensionKind: String, Codable, Sendable { case command, panel, viewer, editor }
public enum ExtensionLifecycle: String, Sendable { case starting, running, finished }
public struct ExtensionAPIError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
public struct ExtensionEntry: Codable, Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public init(name: String, isDirectory: Bool, size: Int64) {
        self.name = name; self.isDirectory = isDirectory; self.size = size
    }
}
public struct ExtensionRow: Codable, Equatable, Sendable {
    public let label: String
    public let value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
}
/// Optional API v1 text-tool settings. Older extensions can ignore this field.
public struct ExtensionTextOptions: Codable, Equatable, Sendable {
    public let rightMargin: Int
    public let reformat: Bool
    public let smartMode: Bool
    public let justify: Bool
    public let tabSize: Int
    public init(rightMargin: Int = 75, reformat: Bool = true, smartMode: Bool = false, justify: Bool = false, tabSize: Int = 8) {
        self.rightMargin = rightMargin; self.reformat = reformat; self.smartMode = smartMode
        self.justify = justify; self.tabSize = tabSize
    }
}
public struct ExtensionRequest: Codable, Sendable {
    public let apiVersion: Int
    public let kind: ExtensionKind
    public let text: String?
    public let entries: [ExtensionEntry]
    public let options: ExtensionTextOptions?
    public init(apiVersion: Int = 1, kind: ExtensionKind, text: String? = nil, entries: [ExtensionEntry] = [], options: ExtensionTextOptions? = nil) {
        self.apiVersion = apiVersion; self.kind = kind; self.text = text; self.entries = entries
        self.options = options
    }
}
public struct ExtensionResponse: Codable, Sendable {
    public let apiVersion: Int
    public let kind: ExtensionKind
    public let title: String
    public let text: String?
    public let rows: [ExtensionRow]
    public init(apiVersion: Int = 1, kind: ExtensionKind, title: String, text: String? = nil, rows: [ExtensionRow] = []) {
        self.apiVersion = apiVersion; self.kind = kind; self.title = title; self.text = text; self.rows = rows
    }
}
public struct ExtensionDescriptor: Sendable {
    public let id: String
    public let title: String
    public let apiVersion: Int
    public let kind: ExtensionKind
    public let executableURL: URL
    public let arguments: [String]
    public init(id: String, title: String, apiVersion: Int = 1, kind: ExtensionKind, executableURL: URL, arguments: [String] = []) {
        self.id = id; self.title = title; self.apiVersion = apiVersion; self.kind = kind
        self.executableURL = executableURL; self.arguments = arguments
    }
}
public final class ExtensionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public struct ExtensionInvocation: Sendable {
    public let response: ExtensionResponse
    public let lifecycle: [ExtensionLifecycle]
}

/// Executes only the descriptor explicitly supplied by the caller. This is crash isolation,
/// not an OS security sandbox: the executable runs with the user's operating-system rights.
public struct ExtensionHost: Sendable {
    public let timeout: TimeInterval
    public let maximumBytes: Int
    public init(timeout: TimeInterval = 3, maximumBytes: Int = 1_048_576) {
        self.timeout = timeout; self.maximumBytes = maximumBytes
    }
    /// Synchronous: call off the UI thread. Editor output is a proposal, never a disk write.
    public func invoke(_ descriptor: ExtensionDescriptor, request: ExtensionRequest, cancellation: ExtensionCancellation? = nil) throws -> ExtensionInvocation {
        guard descriptor.apiVersion == 1, request.apiVersion == 1 else {
            throw ExtensionAPIError("Incompatible extension API version; supported version is 1.")
        }
        guard descriptor.kind == request.kind else { throw ExtensionAPIError("Extension context does not match its declared kind.") }
        guard timeout.isFinite, timeout > 0, maximumBytes > 0, maximumBytes <= 8_388_608 else {
            throw ExtensionAPIError("Invalid extension execution limits.")
        }
        guard cancellation?.isCancelled != true else { throw ExtensionAPIError("Extension cancelled.") }
        let input = try JSONEncoder().encode(request)
        guard input.count <= maximumBytes else { throw ExtensionAPIError("Extension input exceeds the byte limit.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FarExtension-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.json")
        try input.write(to: inputURL)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }
        let output = Pipe(), errors = Pipe()
        for handle in [output.fileHandleForReading, errors.fileHandleForReading] {
            _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK)
        }
        defer {
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        }
        let process = try ExtensionProcess(descriptor: descriptor, directory: directory,
                                           input: inputHandle.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor,
                                           errors: errors.fileHandleForWriting.fileDescriptor)
        // Parent must release write ends so EOF is observable.
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        // Each invocation owns its process group. Cleanup also runs after success,
        // so helpers cannot outlive a one-request extension session.
        defer { process.finish() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var stdout = Data(), stderr = Data(), totalBytes = 0
        func drain(_ handle: FileHandle, into data: inout Data) throws {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                if count <= 0 { return }
                guard totalBytes + count <= maximumBytes else {
                    throw ExtensionAPIError("Extension output exceeds the byte limit.")
                }
                totalBytes += count
                if cancellation?.isCancelled == true { throw ExtensionAPIError("Extension cancelled.") }
                data.append(contentsOf: buffer.prefix(count))
                if ProcessInfo.processInfo.systemUptime >= deadline { throw ExtensionAPIError("Extension timed out.") }
            }
        }
        repeat {
            if cancellation?.isCancelled == true { throw ExtensionAPIError("Extension cancelled.") }
            try drain(output.fileHandleForReading, into: &stdout)
            try drain(errors.fileHandleForReading, into: &stderr)
            if try !process.isRunning() { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ExtensionAPIError("Extension timed out.") }
            Thread.sleep(forTimeInterval: 0.005)
        } while true
        try drain(output.fileHandleForReading, into: &stdout)
        try drain(errors.fileHandleForReading, into: &stderr)
        guard process.status == 0 else {
            throw ExtensionAPIError("Extension failed (wait status \(process.status)).")
        }
        // Bound parser nesting before decoding untrusted output.
        var depth = 0, quoted = false, escaped = false
        for byte in stdout {
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 16 { throw ExtensionAPIError("Extension JSON is too deeply nested.") } }
            else if byte == 125 || byte == 93 { depth -= 1 }
        }
        let response: ExtensionResponse
        do { response = try JSONDecoder().decode(ExtensionResponse.self, from: stdout) }
        catch { throw ExtensionAPIError("Malformed extension response JSON.") }
        guard response.apiVersion == 1 else { throw ExtensionAPIError("Incompatible extension response API version; supported version is 1.") }
        guard response.kind == request.kind, !response.title.isEmpty, response.title.count <= 256,
              response.rows.count <= 10_000 else { throw ExtensionAPIError("Invalid extension response context or metadata.") }
        if response.kind == .panel {
            guard response.text == nil else { throw ExtensionAPIError("Panel extensions must return rows only.") }
        } else {
            guard response.text != nil, response.rows.isEmpty else { throw ExtensionAPIError("Text extensions must return text only.") }
        }
        return ExtensionInvocation(response: response, lifecycle: [.starting, .running, .finished])
    }
}

/// A new process group is created atomically with spawn, avoiding a race between
/// exec and setpgid. This is lifecycle ownership, not a security boundary: a
/// deliberately detached descendant can leave the group using setsid/setpgid.
private final class ExtensionProcess {
    private let pid: pid_t
    private var reaped = false
    private(set) var status: Int32 = 0
    init(descriptor: ExtensionDescriptor, directory: URL, input: Int32, output: Int32, errors: Int32) throws {
        guard descriptor.executableURL.isFileURL, descriptor.executableURL.path.hasPrefix("/"),
              !descriptor.executableURL.path.utf8.contains(0), descriptor.arguments.count <= 100,
              descriptor.arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 65_536 }) else {
            throw ExtensionAPIError("Invalid extension executable or arguments.")
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func checked(_ result: Int32) throws {
            guard result == 0 else { throw ExtensionAPIError("Could not launch extension (\(result)).") }
        }
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, errors, STDERR_FILENO))
        try directory.path.withCString { try checked(posix_spawn_file_actions_addchdir_np(&actions, $0)) }
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        var mask = sigset_t(); sigemptyset(&mask)
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGPIPE)
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        let strings = [descriptor.executableURL.path] + descriptor.arguments
        var argv = strings.map { strdup($0) } + [nil]
        let environmentStrings: [String] = ["PATH=/usr/bin:/bin", "LANG=en_US.UTF-8", "PYTHONDONTWRITEBYTECODE=1"]
        var environment: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) } + [nil]
        defer { for pointer in argv + environment { free(pointer) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else {
            throw ExtensionAPIError("Could not allocate extension arguments.")
        }
        var child: pid_t = 0
        try descriptor.executableURL.path.withCString { path in
            try checked(posix_spawn(&child, path, &actions, &attributes, &argv, &environment))
        }
        pid = child
    }
    func isRunning() throws -> Bool {
        if reaped { return false }
        while true {
            var info = siginfo_t()
            // Keep the group leader waitable until its group is killed. Reaping
            // first would permit PID/group-ID reuse before the cleanup signal.
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if result == 0, info.si_pid == 0 { return true }
            if result == 0 { finish(); return false }
            if errno == EINTR { continue }
            throw ExtensionAPIError("Could not read extension process status (\(errno)).")
        }
    }
    func finish() {
        if reaped { return }
        kill(-pid, SIGKILL)
        // A direct child cannot escape reaping even if it changed its process group.
        kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        reaped = true
    }
}
