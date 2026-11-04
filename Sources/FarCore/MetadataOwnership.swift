import Foundation
import Darwin

public struct MetadataGroup: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public var title: String { "\(name) (GID \(id))" }
}

public struct MetadataOwnershipSnapshot: Sendable {
    public let ownerID: UInt32
    public let ownerName: String
    public let groupID: UInt32
    public let groupName: String
    public var isOwnedByCurrentUser: Bool { ownerID == geteuid() }
}

/// POSIX ownership inspection and the groups available without privilege escalation.
/// UID reassignment is deliberately not offered: macOS requires elevated privileges.
public enum MetadataOwnership {
    public static func snapshot(url: URL) throws -> MetadataOwnershipSnapshot {
        guard url.isFileURL else { throw Failure("Свойства владельца доступны только для локального пути.") }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw Failure("Не удалось прочитать владельца: \(String(cString: strerror(errno)))") }
        return MetadataOwnershipSnapshot(ownerID: info.st_uid, ownerName: ownerName(info.st_uid),
            groupID: info.st_gid, groupName: groupName(info.st_gid))
    }

    public static func availableGroups() throws -> [MetadataGroup] {
        // Retry if group membership changes between the count and data calls.
        for _ in 0..<3 {
            let count = getgroups(0, nil)
            guard count >= 0 else { throw Failure("Не удалось прочитать группы текущего пользователя.") }
            var groups = [gid_t](repeating: 0, count: Int(count))
            let actual = groups.withUnsafeMutableBufferPointer { getgroups(count, $0.baseAddress) }
            if actual < 0 { if errno == EINVAL { continue }; throw Failure("Не удалось прочитать группы текущего пользователя.") }
            var identifiers = Set(groups.prefix(Int(actual)))
            identifiers.insert(getegid())
            identifiers.remove(gid_t.max) // fchown uses this value as "leave unchanged".
            return identifiers.sorted().map { MetadataGroup(id: $0, name: groupName($0)) }
        }
        throw Failure("Список групп изменился. Повторите предпросмотр.")
    }

    private static func ownerName(_ id: uid_t) -> String {
        var value = passwd(), result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 65_536)
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(id, &value, bytes.baseAddress!, bytes.count, &result) == 0,
                  result != nil, let name = value.pw_name else { return String(id) }
            return String(cString: name)
        }
    }
    private static func groupName(_ id: gid_t) -> String {
        var value = group(), result: UnsafeMutablePointer<group>?
        var buffer = [CChar](repeating: 0, count: 65_536)
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard getgrgid_r(id, &value, bytes.baseAddress!, bytes.count, &result) == 0,
                  result != nil, let name = value.gr_name else { return String(id) }
            return String(cString: name)
        }
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
