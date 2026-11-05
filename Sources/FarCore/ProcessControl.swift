import Foundation
import Darwin

/// PID plus kernel start time. A PID alone is never accepted for a process mutation.
public struct ProcessIdentity: Sendable, Equatable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let userID: UInt32
}

public enum ProcessControl {
    public static func identity(pid: Int32) throws -> ProcessIdentity {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            throw PanelSessionError("Процесс завершился или недоступен. Обновите панель.")
        }
        return ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec, userID: info.pbi_uid)
    }
    public static func verify(_ expected: ProcessIdentity) throws {
        guard try identity(pid: expected.pid) == expected else {
            throw PanelSessionError("Процесс с этим PID изменился. Обновите панель.")
        }
    }
    public static func priority(_ expected: ProcessIdentity) throws -> Int32 {
        try verify(expected); errno = 0
        let value = getpriority(PRIO_PROCESS, id_t(expected.pid))
        guard errno == 0 else { throw failure() }
        return value
    }
    /// FAR ProcList terminates the selected process, not its children.
    public static func terminate(_ expected: ProcessIdentity) throws {
        try validateMutation(expected)
        guard kill(expected.pid, SIGKILL) == 0 else { throw failure() }
    }
    /// macOS exposes niceness rather than the Windows priority classes.
    public static func changePriority(_ expected: ProcessIdentity, increase: Bool) throws {
        let current = try priority(expected)
        let next = min(20, max(-20, current + (increase ? -1 : 1)))
        try validateMutation(expected)
        guard setpriority(PRIO_PROCESS, id_t(expected.pid), next) == 0 else { throw failure() }
    }
    private static func validateMutation(_ expected: ProcessIdentity) throws {
        guard expected.pid > 1, expected.pid != getpid() else {
            throw PanelSessionError("Этот процесс нельзя изменить из панели.")
        }
        try verify(expected)
    }
    private static func failure() -> PanelSessionError {
        let code = errno
        return PanelSessionError("macOS: " + String(cString: strerror(code)))
    }
}

