import Foundation
import Darwin
import Testing
@testable import FarCore

extension SFTPPasswordTests {
    private var endpoint: SFTPAuthenticationEndpoint {
        SFTPAuthenticationEndpoint(host: "trusted.example", port: 2222, username: "alice", jumpHostIndex: 1)
    }

    @Test func challengeValidatesAndConsumesExactlyOnce() throws {
        let request = SFTPAuthenticationChallenge(endpoint: endpoint, prompt: "Code:")
        let finished = LockedValues<Int>()
        request.whenFinished { finished.append(1) }
        for invalid in ["a\nb", "a\rb", "a\0b", String(repeating: "é", count: 512)] {
            #expect(throws: SFTPError.invalidPassword) { try request.respond(invalid) }
            #expect(request.isPending)
        }
        try request.respond(String(repeating: "é", count: 511) + "a")
        #expect(!request.isPending)
        #expect(try request.takeResult()?.get().utf8.count == 1023)
        #expect(request.takeResult() == nil)
        request.whenFinished { finished.append(2) }
        #expect(finished.values == [1, 2])
        #expect(throws: SFTPError.cancelled) { try request.respond("again") }
        request.finish(); request.finish()
        #expect(finished.values == [1, 2])
    }

    @Test func emptyResponseAndCancellationAreDistinct() throws {
        let empty = SFTPAuthenticationChallenge(endpoint: endpoint, prompt: "Optional:")
        try empty.respond("")
        #expect(try empty.takeResult()?.get() == "")
        let cancelled = SFTPAuthenticationChallenge(endpoint: endpoint, prompt: "OTP:")
        try cancelled.respond(nil)
        #expect(throws: SFTPError.cancelled) { _ = try cancelled.takeResult()?.get() }
    }

    @Test func stoppedChallengeDiscardsSecretsAndNotifiesLateObservers() throws {
        let request = SFTPAuthenticationChallenge(endpoint: endpoint, prompt: "OTP:")
        try request.respond("secret"); request.finish()
        #expect(request.takeResult() == nil)
        let finished = LockedValues<Int>()
        request.whenFinished { finished.append(1) }
        #expect(finished.values == [1])
        #expect(throws: SFTPError.cancelled) { try request.respond("late") }
    }

    @Test func responseAndFinishRaceCompletesOnce() {
        for _ in 0..<100 {
            let request = SFTPAuthenticationChallenge(endpoint: endpoint, prompt: "OTP:")
            let finished = LockedValues<Int>()
            request.whenFinished { finished.append(1) }
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { try? request.respond("123456") } else { request.finish() }
            }
            #expect(!request.isPending)
            #expect(finished.values == [1])
            #expect(request.takeResult() == nil)
        }
    }

    @Test func inheritedInteractiveHooksAreRemoved() {
        let environment = SFTPPasswordPrompt.sanitizedEnvironment([
            "FARMAC_SFTP_REQUEST_FIFO": "untrusted", "FARMAC_SFTP_RESPONSE_FIFO": "untrusted",
            "FARMAC_SFTP_PASSWORD_FIFO": "untrusted", "SSH_ASKPASS_PROMPT": "confirm", "ENV": "untrusted", "PATH": "/usr/bin:/bin"
        ])
        #expect(environment == ["PATH": "/usr/bin:/bin"])
    }

    @Test func safePromptPreservesUnicodeAndRemovesControls() throws {
        #expect(try SFTPInteractivePrompt.displayPrompt(Data("Код \u{1b}[31m\u{202e}OTP:\n\t".utf8)) == "Код [31mOTP:\n\t")
        for invalid in [Data([0xff]), Data([0]), Data(repeating: 65, count: 4097)] {
            #expect(throws: SFTPError.self) { _ = try SFTPInteractivePrompt.displayPrompt(invalid) }
        }
    }

    @Test func interactiveFlagsAllowKeyThenOTP() throws {
        let connection = NetworkConnection(kind: .sftp, host: "target.example", username: "alice", privateKeyPath: "/tmp/key", sftpAuthenticationMode: .interactive)
        let args = try SFTPProvider.sshArguments(connection: connection, knownHostsURL: URL(fileURLWithPath: "/tmp/known"))
        for flag in ["BatchMode=no", "KbdInteractiveAuthentication=yes", "PasswordAuthentication=no", "PreferredAuthentications=publickey,keyboard-interactive", "UseKeychain=no", "AddKeysToAgent=no", "StrictHostKeyChecking=yes", "IdentitiesOnly=yes", "/tmp/key"] {
            #expect(args.contains(flag))
        }
        #expect(!args.contains("PubkeyAuthentication=no"))
    }

    @Test func jumpModesRoundTripAndLegacyDefaults() throws {
        let legacy = Data(#"{"host":"jump.example","port":22,"username":"alice","privateKeyPath":"/tmp/key"}"#.utf8)
        #expect(try JSONDecoder().decode(SFTPJumpHost.self, from: legacy).authenticationMode == .keyAgent)
        for mode in SFTPAuthenticationMode.allCases {
            let jump = SFTPJumpHost(host: "jump.example", username: "alice", authenticationMode: mode)
            let encoded = try JSONEncoder().encode(jump)
            #expect(try JSONDecoder().decode(SFTPJumpHost.self, from: encoded) == jump)
            #expect(!String(decoding: encoded, as: UTF8.self).contains("secret"))
            let args = try SFTPTunnelChain.arguments(jump: jump, endpointHost: "127.0.0.1", endpointPort: 2345,
                nextHost: "target.example", nextPort: 22, localPort: 3456, knownHostsURL: URL(fileURLWithPath: "/tmp/known"),
                controlURL: URL(fileURLWithPath: "/tmp/control"), timeout: 10)
            #expect(args.contains("StrictHostKeyChecking=yes"))
            #expect(args.contains("HostKeyAlias=[jump.example]:22"))
            #expect(args.contains("BatchMode=\(mode == .keyAgent ? "yes" : "no")"))
            #expect(args.contains("PasswordAuthentication=\(mode == .password ? "yes" : "no")"))
        }
    }

    @Test func helpersPerformRepeatedRoundsWithoutEvaluatingText() throws {
        let observed = LockedValues<SFTPAuthenticationChallenge>()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("farmac-noexec-" + UUID().uuidString)
        let secret = "  $HOME `touch \(marker.path)` ' \\ пароль  "
        let process = try SFTPProcess(executable: "/bin/sh", arguments: ["-p", "-c", #"""
            "$SSH_ASKPASS" 'Password: $HOME `echo literal`'
            "$SSH_ASKPASS" 'OTP:'
            "$SSH_ASKPASS" 'Optional:'
            """#], cancellation: TransferCancellation(), timeout: 2, authenticationEndpoint: endpoint, authenticationHandler: { challenge in
                observed.append(challenge)
                try? challenge.respond(challenge.prompt == "Optional:" ? "" : secret)
            })
        defer { process.stop() }
        let expected = Data((secret + "\n" + secret + "\n\n").utf8)
        #expect(try process.read(expected.count) == expected)
        #expect(observed.values.count == 3)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(observed.values.allSatisfy { $0.endpoint == endpoint && !$0.isPending })
    }

    @Test func interactiveBridgePermissionsAndHints() throws {
        let bridge = try SFTPInteractivePrompt(endpoint: endpoint, handler: nil)
        defer { bridge.stop() }
        for (url, permissions) in [(bridge.directory, 0o700), (bridge.helperURL, 0o700), (bridge.requestURL, 0o600), (bridge.responseURL, 0o600)] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == permissions)
        }
        for url in [bridge.requestURL, bridge.responseURL] {
            var info = Darwin.stat()
            #expect(lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO)
        }
        for hint in ["confirm", "none"] {
            let child = Process(); let output = Pipe()
            child.executableURL = bridge.helperURL; child.arguments = ["Never approve this"]
            child.environment = bridge.environment.merging(["SSH_ASKPASS_PROMPT": hint]) { _, new in new }
            child.standardOutput = output
            try child.run(); child.waitUntilExit()
            #expect(child.terminationStatus != 0)
            #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
        bridge.stop(); bridge.stop()
        #expect(!FileManager.default.fileExists(atPath: bridge.directory.path))
    }

    @Test func unansweredInputHonorsDeadlineAndFinishesDialog() throws {
        let observed = LockedValues<SFTPAuthenticationChallenge>()
        let process = try SFTPProcess(executable: "/bin/sh", arguments: ["-p", "-c", #"exec "$SSH_ASKPASS" 'OTP:'"#],
            cancellation: TransferCancellation(), timeout: 0.25, authenticationEndpoint: endpoint, authenticationHandler: { observed.append($0) })
        defer { process.stop() }
        #expect(throws: SFTPError.timedOut) { _ = try process.read(1) }
        #expect(observed.values.count == 1)
        #expect(observed.values.allSatisfy { !$0.isPending })
    }

    @Test func cancellationAndUserCancellationFinishDialog() throws {
        for userCancels in [true, false] {
            let cancellation = TransferCancellation()
            let observed = LockedValues<SFTPAuthenticationChallenge>()
            let process = try SFTPProcess(executable: "/bin/sh", arguments: ["-p", "-c", #"exec "$SSH_ASKPASS" 'OTP:'"#],
                cancellation: cancellation, timeout: 2, authenticationEndpoint: endpoint, authenticationHandler: {
                    observed.append($0)
                    if userCancels { try? $0.respond(nil) } else { cancellation.cancel() }
                })
            defer { process.stop() }
            #expect(throws: SFTPError.cancelled) { _ = try process.read(1) }
            #expect(observed.values.count == 1)
            #expect(observed.values.allSatisfy { !$0.isPending })
        }
    }

    @Test func cancellationStopsSSHBeforeReleasingAskpassFailure() throws {
        // Mimic OpenSSH translating a failed askpass helper into an empty reply.
        // Ignore TERM so this also proves the bounded KILL path runs before release.
        for userCancels in [false, true] {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("farmac-cancelled-answer-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: marker) }
            let process = try SFTPProcess(executable: "/bin/sh", arguments: ["-p", "-c", #"""
                trap '' TERM
                "$SSH_ASKPASS" 'OTP:' >/dev/null
                : > "$1"
                """#, "cancel-test", marker.path], cancellation: TransferCancellation(), timeout: userCancels ? 3 : 0.5,
                authenticationEndpoint: endpoint, authenticationHandler: {
                    if userCancels { try? $0.respond(nil) }
                })
            defer { process.stop() }
            #expect(throws: userCancels ? SFTPError.cancelled : SFTPError.timedOut) { _ = try process.read(1) }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func missingHandlerFailsClearlyWithoutWaitingForTimeout() throws {
        let process = try SFTPProcess(executable: "/bin/sh", arguments: ["-p", "-c", #"exec "$SSH_ASKPASS" 'OTP:'"#],
            cancellation: TransferCancellation(), timeout: 2, authenticationEndpoint: endpoint)
        defer { process.stop() }
        do { _ = try process.read(1); Issue.record("Missing handler must fail") }
        catch SFTPError.unsupported(let message) { #expect(message.contains("обработчик")) }
    }

    @Test func roundsAreBoundedPerProcess() throws {
        let observed = LockedValues<Int>()
        let process = try SFTPProcess(executable: "/bin/sh", arguments: ["-p", "-c", #"while :; do "$SSH_ASKPASS" 'OTP:' >/dev/null; done"#],
            cancellation: TransferCancellation(), timeout: 3, authenticationEndpoint: endpoint, authenticationHandler: {
                observed.append(1); try? $0.respond("123456")
            })
        defer { process.stop() }
        do { _ = try process.read(1); Issue.record("Round limit must fail") }
        catch SFTPError.unsupported(let message) { #expect(message.contains("лимит")) }
        #expect(observed.values.count == 16)
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return items }
    func append(_ value: Value) { lock.lock(); items.append(value); lock.unlock() }
}
