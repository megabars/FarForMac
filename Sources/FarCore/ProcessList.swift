import Foundation
import Darwin

public struct ProcessListEntry: Sendable, Equatable {
    public let pid: Int32
    public let parentPID: Int32
    public let userID: UInt32
    public let cpuPercent: Double
    public let residentBytes: Int64
    public let executable: String
    public var identity: ProcessIdentity? = nil
    public var name: String { (executable as NSString).lastPathComponent }
}

/// A local read-only snapshot. Command arguments and environments are not collected.
public enum ProcessList {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumCount = 20_000

    public static func snapshot(cancellation: TransferCancellation = TransferCancellation()) throws -> [ProcessListEntry] {
        if cancellation.isCancelled { throw ViewerError.cancelled }
        // Bind ps rows only to processes that existed with the same identity
        // before and after collection. A recycled PID remains read-only.
        var pids = [Int32](repeating: 0, count: maximumCount)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var before: [Int32: ProcessIdentity] = [:]
        if count > 0, count <= maximumCount {
            for pid in pids.prefix(Int(count)) {
                if cancellation.isCancelled { throw ViewerError.cancelled }
                if let identity = try? ProcessControl.identity(pid: pid) { before[pid] = identity }
            }
        }
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Aww", "-o", "pid=,ppid=,uid=,%cpu=,rss=,comm="]
        task.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        task.standardInput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        task.standardOutput = output
        defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        try task.run()
        defer {
            if task.isRunning {
                task.terminate()
                let until = ProcessInfo.processInfo.systemUptime + 0.2
                while task.isRunning && ProcessInfo.processInfo.systemUptime < until { usleep(5_000) }
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            }
        }
        try output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) >= 0 else { throw PanelSessionError("Не удалось прочитать список процессов.") }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            if cancellation.isCancelled { throw ViewerError.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw PanelSessionError("Истекло время получения списка процессов.") }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count > 0 {
                guard count <= maximumBytes - bytes.count else { throw PanelSessionError("Список процессов превышает допустимый размер.") }
                bytes.append(contentsOf: buffer.prefix(count))
            } else if errno == EAGAIN || errno == EINTR { usleep(10_000) }
            else { throw PanelSessionError("Не удалось прочитать список процессов.") }
        }
        while task.isRunning {
            if cancellation.isCancelled { throw ViewerError.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw PanelSessionError("Истекло время получения списка процессов.") }
            usleep(5_000)
        }
        guard task.terminationStatus == 0 else { throw PanelSessionError("macOS не разрешила получить список процессов.") }
        if cancellation.isCancelled { throw ViewerError.cancelled }
        return try parse(bytes).map { entry in
            var captured = entry
            if let first = before[entry.pid], let current = try? ProcessControl.identity(pid: entry.pid), first == current {
                captured.identity = current
            }
            return captured
        }
    }

    static func parse(_ data: Data) throws -> [ProcessListEntry] {
        guard data.count <= maximumBytes else { throw PanelSessionError("Список процессов превышает допустимый размер.") }
        let text = String(decoding: data, as: UTF8.self)
        var entries: [ProcessListEntry] = [], seen = Set<Int32>()
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = line.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 6, let pid = Int32(fields[0]), pid >= 0,
                  let parent = Int32(fields[1]), parent >= 0, let uid = UInt32(fields[2]),
                  let cpu = Double(fields[3]), cpu.isFinite, cpu >= 0,
                  let kib = Int64(fields[4]), kib >= 0, kib <= Int64.max / 1024,
                  seen.insert(pid).inserted else { throw PanelSessionError("Неверный формат списка процессов macOS.") }
            entries.append(ProcessListEntry(pid: pid, parentPID: parent, userID: uid, cpuPercent: cpu,
                residentBytes: kib * 1024, executable: String(fields[5]).trimmingCharacters(in: .whitespaces)))
            guard entries.count <= maximumCount else { throw PanelSessionError("В списке более 20 000 процессов.") }
        }
        return entries.sorted { $0.cpuPercent == $1.cpuPercent ? $0.pid < $1.pid : $0.cpuPercent > $1.cpuPercent }
    }
}
