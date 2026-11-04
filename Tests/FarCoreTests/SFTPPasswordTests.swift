import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite(.serialized)
struct SFTPPasswordTests {
    @Test func passwordModeDisablesOtherAuthentication() throws {
        let connection = NetworkConnection(kind: .sftp, host: "example.test", username: "user", privateKeyPath: "/tmp/key")
        let args = try SFTPProvider.sshArguments(connection: connection, knownHostsURL: URL(fileURLWithPath: "/tmp/hosts"), passwordAuthentication: true)
        for option in ["BatchMode=no", "PasswordAuthentication=yes", "PreferredAuthentications=password", "PubkeyAuthentication=no", "KbdInteractiveAuthentication=no", "NumberOfPasswordPrompts=1", "UseKeychain=no", "StrictHostKeyChecking=yes"] {
            #expect(args.contains(option))
        }
        #expect(!args.contains("/tmp/key"))
    }

    @Test func helperPreservesLiteralPasswordAndCleansUp() throws {
        let password = "  кавычки '\" $HOME `echo secret` \\ end  "
        let prompt = try SFTPPasswordPrompt(password: password)
        let directory = prompt.directory
        defer { prompt.stop() }
        #expect(!prompt.environment.values.contains(password))
        #expect(!(try String(contentsOf: prompt.helperURL, encoding: .utf8)).contains(password))
        for (url, permissions) in [(directory, 0o700), (prompt.helperURL, 0o700), (prompt.fifoURL, 0o600)] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == permissions)
        }
        var info = Darwin.stat()
        #expect(lstat(prompt.fifoURL.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFIFO)
        let process = Process(); let output = Pipe()
        process.executableURL = prompt.helperURL; process.environment = prompt.environment; process.standardOutput = output
        try process.run()
        let actual = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(actual == Data((password + "\n").utf8))
        prompt.stop(); prompt.stop()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func passwordModeRequiresExplicitSecretBeforeLaunchingSSH() throws {
        var connection = NetworkConnection(kind: .sftp, host: "example.test", username: "user")
        connection.sftpAuthenticationMode = .password
        for password: String? in [nil, ""] {
            let provider = SFTPProvider(connection: connection, password: password)
            #expect(throws: SFTPError.invalidConfiguration) {
                _ = try provider.list(path: "/", cancellation: TransferCancellation())
            }
        }
    }

    @Test func rejectsUnrepresentablePasswords() throws {
        for password in ["a\nb", "a\rb", "a\0b", String(repeating: "é", count: 512), String(repeating: "a", count: 1024)] {
            #expect(throws: SFTPError.invalidPassword) { _ = try SFTPPasswordPrompt(password: password) }
        }
        let empty = try SFTPPasswordPrompt(password: ""); empty.stop()
        let maximum = try SFTPPasswordPrompt(password: String(repeating: "é", count: 511) + "a"); maximum.stop()
    }

    @Test func helperRefusesConfirmationWithoutConsumingPassword() throws {
        let prompt = try SFTPPasswordPrompt(password: "secret")
        defer { prompt.stop() }
        for hint in ["confirm", "none"] {
            let process = Process(); let output = Pipe()
            process.executableURL = prompt.helperURL
            process.environment = prompt.environment.merging(["SSH_ASKPASS_PROMPT": hint]) { _, new in new }
            process.standardOutput = output
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus != 0)
            #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
        let process = Process(); let output = Pipe()
        process.executableURL = prompt.helperURL; process.environment = prompt.environment; process.standardOutput = output
        try process.run()
        #expect(output.fileHandleForReading.readDataToEndOfFile() == Data("secret\n".utf8))
        process.waitUntilExit()
    }

    @Test func passwordDiagnosticsNeverExposeWholeOrTruncatedSecrets() {
        let secret = "  literal $пароль \\ '  "
        let generic = SFTPProvider.transportDiagnostics("", passwordAuthentication: true)
        for diagnostic in [secret, "error: " + secret, String(secret.dropFirst(2)), String(secret.dropLast(3)), "Permission denied"] {
            #expect(SFTPProvider.transportDiagnostics(diagnostic, passwordAuthentication: true) == generic)
        }
        #expect(SFTPProvider.transportDiagnostics("  key error\n", passwordAuthentication: false) == "key error")
    }

    @Test func inheritedAskpassAndShellHooksAreRemoved() {
        let environment = SFTPPasswordPrompt.sanitizedEnvironment(["SSH_ASKPASS": "evil", "SSH_ASKPASS_REQUIRE": "prefer", "FARMAC_SFTP_PASSWORD_FIFO": "old", "ENV": "evil", "BASH_ENV": "evil", "PATH": "/usr/bin:/bin"])
        #expect(environment == ["PATH": "/usr/bin:/bin"])
    }
}
