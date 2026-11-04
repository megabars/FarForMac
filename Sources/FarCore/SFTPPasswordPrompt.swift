import Foundation
import Darwin

/// A one-shot askpass bridge. Only the FIFO contains the secret; the helper is constant code.
final class SFTPPasswordPrompt {
    let directory: URL
    let fifoURL: URL
    let helperURL: URL
    private var descriptor: Int32 = -1
    private var stopped = false

    var environment: [String: String] {
        ["SSH_ASKPASS": helperURL.path, "SSH_ASKPASS_REQUIRE": "force",
         "FARMAC_SFTP_PASSWORD_FIFO": fifoURL.path, "DISPLAY": "farmac:0"]
    }

    static func sanitizedEnvironment(_ inherited: [String: String]) -> [String: String] {
        inherited.filter { key, _ in
            !key.hasPrefix("SSH_ASKPASS") && !key.hasPrefix("BASH_FUNC_") && !key.hasPrefix("FARMAC_SFTP_") &&
            !["ENV", "BASH_ENV", "SHELLOPTS", "BASHOPTS", "CDPATH"].contains(key)
        }
    }

    init(password: String) throws {
        guard password.utf8.count <= 1023, !password.contains("\0"),
              !password.contains(where: { $0.isNewline }) else { throw SFTPError.invalidPassword }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("farmac-askpass-" + UUID().uuidString)
        fifoURL = directory.appendingPathComponent("password")
        helperURL = directory.appendingPathComponent("askpass")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            guard mkfifo(fifoURL.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            let helper = """
            #!/bin/sh -p
            [ -z "${SSH_ASKPASS_PROMPT:-}" ] || exit 1
            IFS= read -r password < "$FARMAC_SFTP_PASSWORD_FIFO" || exit 1
            printf '%s\\n' "$password"
            """ + "\n"
            try Data(helper.utf8).write(to: helperURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
            descriptor = open(fifoURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            var bytes = Array(password.utf8) + [10]
            defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            guard count == bytes.count else { throw POSIXError(.EIO) }
        } catch { stop(); throw error }
    }

    func stop() {
        guard !stopped else { return }; stopped = true
        // Unlink while a writer still exists: a concurrently starting helper must
        // either open successfully or fail, never block opening a writerless FIFO.
        try? FileManager.default.removeItem(at: directory)
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { stop() }
}
