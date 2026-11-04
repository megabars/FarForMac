import Foundation
import Darwin
import CryptoKit

/// Detects pin/explicit identity changes without following a FIFO, device, or an
/// unbounded trust file. Only a digest survives the read; private key bytes are
/// neither retained by the session nor written elsewhere.
enum SFTPTrustSnapshot {
    static let maximumFileBytes = 1024 * 1024

    static func capture(knownHostsURL: URL, identities: [String], cancellation: TransferCancellation,
                        connectionCancellation: TransferCancellation, timeout: Double) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func check() throws {
            if cancellation.isCancelled || connectionCancellation.isCancelled { throw SFTPError.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw SFTPError.timedOut }
        }
        var digest = SHA256()
        for (url, identity) in [(knownHostsURL, false)] + identities.map({ (URL(fileURLWithPath: $0), true) }) {
            try check()
            // Explicit identity symlinks are supported by OpenSSH. Resolve the
            // selected path, include its target in the fingerprint, and still
            // open the final component without following replacement symlinks.
            let selected = identity ? url.resolvingSymlinksInPath() : url
            digest.update(data: SFTPPacket.string(url.path))
            digest.update(data: SFTPPacket.string(selected.path))
            let fd = open(selected.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                if errno == ENOENT { digest.update(data: Data([0])); continue }
                throw SFTPError.invalidConfiguration
            }
            defer { Darwin.close(fd) }
            var before = Darwin.stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_size >= 0, before.st_size <= maximumFileBytes else { throw SFTPError.invalidConfiguration }
            digest.update(data: Data([1]))
            digest.update(data: SFTPPacket.uint64(UInt64(before.st_size)))
            var total = 0, buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                try check()
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SFTPError.invalidConfiguration
                }
                if count == 0 { break }
                total += count
                guard total <= maximumFileBytes else { throw SFTPError.invalidConfiguration }
                digest.update(data: Data(buffer.prefix(count)))
            }
            var after = Darwin.stat()
            guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size, total == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  !identity || url.resolvingSymlinksInPath() == selected else { throw SFTPError.invalidConfiguration }
        }
        try check()
        return Data(digest.finalize())
    }
}
