import Darwin
import Foundation

public struct FarCmdsCapturedOutput: Equatable, Sendable {
    public let primary: Data
    public let standardError: Data?
    public let console: Data
    public let exitCode: Int32
}

public struct FarCmdsCaptureRunner: Sendable {
    public let timeout: TimeInterval
    public let outputLimit: Int

    public init(timeout: TimeInterval = 60, outputLimit: Int = 16 * 1024 * 1024) {
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    public func run(_ capture: FarCmdsCommand.Capture, directory: URL, environment: [String: String],
                    cancellation: ExtensionCancellation? = nil) throws -> FarCmdsCapturedOutput {
        guard timeout.isFinite, timeout > 0, outputLimit > 0,
              outputLimit <= 128 * 1024 * 1024 else { throw FarCmdsError("Некорректный предел выполнения FAR Commands.") }
        if cancellation?.isCancelled == true { throw CancellationError() }

        let null = URL(fileURLWithPath: "/dev/null")
        let input = try FileHandle(forReadingFrom: null)
        let discard = try FileHandle(forWritingTo: null)
        defer { try? input.close(); try? discard.close() }

        var readers: [(pipe: Pipe, role: Channel)] = []
        func makePipe(_ role: Channel) throws -> FileHandle {
            let pipe = Pipe()
            let fd = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw posix("Настроить канал") }
            readers.append((pipe, role))
            return pipe.fileHandleForWriting
        }
        defer {
            for channel in readers {
                try? channel.pipe.fileHandleForWriting.close()
                try? channel.pipe.fileHandleForReading.close()
            }
        }
        let primary = try makePipe(.primary)
        let stdout: FileHandle, stderr: FileHandle
        switch capture.stream {
        case .combined: stdout = primary; stderr = primary
        case .separate: stdout = primary; stderr = try makePipe(.standardError)
        case .stdout: stdout = primary; stderr = capture.display == .hide ? discard : try makePipe(.console)
        case .stderr: stdout = capture.display == .hide ? discard : try makePipe(.console); stderr = primary
        }
        let environmentStrings = environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
        let process = try ExtensionProcess(executable: URL(fileURLWithPath: "/bin/zsh"),
                                           arguments: ["-c", capture.command], environment: environmentStrings,
                                           directory: directory, input: input.fileDescriptor,
                                           output: stdout.fileDescriptor, errors: stderr.fileDescriptor)
        for channel in readers { try? channel.pipe.fileHandleForWriting.close() }

        var output = Data(), errorOutput = Data(), console = Data()
        var total = 0
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func check() throws {
            if cancellation?.isCancelled == true { throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw FarCmdsError("Время выполнения команды истекло.") }
        }
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain(_ channel: (pipe: Pipe, role: Channel)) throws -> Bool {
            let count = Darwin.read(channel.pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            if count == -1 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return false }
                throw posix("Чтение вывода")
            }
            guard count > 0 else { return false }
            guard count <= outputLimit - total else { throw FarCmdsError("Объём вывода команды превысил предел.") }
            total += count
            let bytes = buffer.prefix(count)
            switch channel.role {
            case .primary: output.append(contentsOf: bytes)
            case .standardError: errorOutput.append(contentsOf: bytes)
            case .console: break
            }
            if channel.role == .console || capture.display == .echo { console.append(contentsOf: bytes) }
            return true
        }
        do {
            while true {
                try check()
                var progressed = false
                for reader in readers { if try drain(reader) { progressed = true } }
                if try !process.isRunning() {
                    for reader in readers {
                        while try drain(reader) { try check() }
                    }
                    break
                }
                if !progressed { Thread.sleep(forTimeInterval: 0.005) }
            }
        } catch {
            let cause = error
            do { try process.finish() }
            catch { throw FarCmdsError(cause.localizedDescription + " " + error.localizedDescription) }
            throw cause
        }
        try check()
        let signal = process.status & 0x7F
        let code = signal == 0 ? (process.status >> 8) & 0xFF : 128 + signal
        return .init(primary: output, standardError: capture.stream == .separate ? errorOutput : nil,
                     console: console, exitCode: code)
    }

    private enum Channel { case primary, standardError, console }

    private func posix(_ operation: String) -> FarCmdsError {
        FarCmdsError(operation + ": " + String(cString: strerror(errno)))
    }
}

public enum FarCmdsFiles {
    public static func resolve(_ path: String, relativeTo directory: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL
    }

    public static func search(_ name: String, from directory: URL, environment: [String: String]) -> URL? {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            let candidate = resolve(name, relativeTo: directory)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        let farHome = environment["FARHOME"].map { [resolve($0, relativeTo: directory)] } ?? []
        let path = (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? directory : resolve(String($0), relativeTo: directory) }
        let directories = name.contains("/") ? [directory] : [directory] + farHome + path
        let extensions = (environment["PATHEXT"] ?? "").split(separator: ";").map(String.init)
        for suffix in [""] + extensions {
            for directory in directories {
                let candidate = resolve(name + suffix, relativeTo: directory)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    public static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0, maximumBytes <= FarCmdsOptions.maximumReadLimit else {
            throw FarCmdsError("Некорректный размер чтения FAR Commands.")
        }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FarCmdsError(String(cString: strerror(errno)) + ": " + url.path) }
        defer { _ = Darwin.close(fd) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            throw FarCmdsError("FAR Commands читает только обычные файлы.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < maximumBytes {
            let length = Darwin.read(fd, &buffer, min(buffer.count, maximumBytes - data.count))
            if length == 0 { break }
            if length < 0 {
                if errno == EINTR { continue }
                throw FarCmdsError(String(cString: strerror(errno)) + ": " + url.path)
            }
            data.append(contentsOf: buffer.prefix(length))
        }
        return data
    }

    public static func text(_ data: Data) -> String {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            let littleEndian = data.starts(with: [0xff, 0xfe])
            var units: [UInt16] = []
            var bytes = data.dropFirst(2).makeIterator()
            while let a = bytes.next(), let b = bytes.next() {
                let value = littleEndian ? UInt16(a) | (UInt16(b) << 8) : (UInt16(a) << 8) | UInt16(b)
                if value == 0 { break }
                units.append(value)
            }
            return String(decoding: units, as: UTF16.self)
        }
        let body = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...]
        let bytes = body.prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .windowsCP1251)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    public static func path(in file: URL, maximumBytes: Int, environment: [String: String]) throws -> String {
        let contents = text(try read(file, maximumBytes: maximumBytes))
        var line = String(contents.prefix { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
        if line.first == "\"", line.last == "\"", line.count > 1 { line = String(line.dropFirst().dropLast()) }
        let value = FarCmdsCommand.expand(line, environment: environment)
        guard !value.isEmpty, !value.utf8.contains(0), value.utf8.count <= 65_536 else {
            throw FarCmdsError("В первой строке файла нет пути.")
        }
        return value
    }
}
