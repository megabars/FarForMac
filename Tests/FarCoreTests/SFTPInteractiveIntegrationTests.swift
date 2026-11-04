import Foundation
import Darwin
import Testing
@testable import FarCore

/// Real OpenSSH against isolated Paramiko endpoints. Keep these in the password
/// suite so global helper cleanup assertions cannot race another SSH test.
extension SFTPPasswordTests {
    @Test func differentPasswordsReachOnlyTheirOwnJumpHosts() throws {
        let resources = authenticationResources(); defer { #expect(authenticationResources().subtracting(resources).isEmpty) }
        let f = try JumpSSHFixture(jumpModes: ["password", "password"]); defer { f.stop() }; try f.trustAll()
        let requests = InteractiveRequests()
        let provider = SFTPProvider(connection: f.connection, password: f.password, knownHostsURL: f.store.url) { challenge in
            requests.append(challenge)
            guard let index = challenge.endpoint.jumpHostIndex else { Issue.record("Static target password unexpectedly requested interactively"); return }
            try? challenge.respond(f.jumpPasswords[index])
        }
        #expect(try provider.list(path: "/", cancellation: TransferCancellation()).contains { $0.name == "hello.txt" })
        #expect(requests.values.map(\.endpoint.jumpHostIndex) == [0, 1])
        for index in 0..<2 {
            let jump = f.connection.sftpJumpHosts[index]
            #expect(requests.values[index].endpoint == SFTPAuthenticationEndpoint(host: jump.host, port: jump.port, username: jump.username, jumpHostIndex: index))
            #expect(f.counter("jump\(index + 1)", "password") == 1)
            #expect(f.counter("jump\(index + 1)", "accepted") == 1)
            #expect(f.counter("jump\(index + 1)", "rejected") == 0)
        }
        #expect(f.counter("target", "password") == 1)
        #expect(requests.allFinished)
        provider.closeConnection()
        #expect(f.waitUntilDisconnected())
        try assertFixtureHasNoSecrets(f)
    }

    @Test func multipleInteractiveRoundsAndPromptsAuthenticateEveryEndpoint() throws {
        let resources = authenticationResources(); defer { #expect(authenticationResources().subtracting(resources).isEmpty) }
        let f = try JumpSSHFixture(targetMode: "interactive", jumpModes: ["interactive", "interactive"])
        defer { f.stop() }; try f.trustAll()
        let requests = InteractiveRequests()
        let provider = SFTPProvider(connection: f.connection, knownHostsURL: f.store.url) { challenge in
            requests.append(challenge)
            // Respond later, as the desktop authentication sheet does.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                try? challenge.respond(fixtureAnswer(challenge, fixture: f))
            }
        }
        #expect(try provider.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        #expect(requests.values.map(\.endpoint.jumpHostIndex) == [0, 0, 0, 1, 1, 1, nil, nil, nil])
        for name in ["jump1", "jump2", "target"] {
            #expect(f.counter(name, "interactive") == 1)
            #expect(f.counter(name, "response") == 2)
            #expect(f.counter(name, "accepted") == 1)
            #expect(f.counter(name, "rejected") == 0)
            #expect(f.counter(name, "password") == 0)
        }
        let target = requests.values.last!.endpoint
        #expect(target == SFTPAuthenticationEndpoint(host: f.connection.host, port: f.connection.port, username: "fixture"))
        #expect(requests.allFinished)
        provider.closeConnection()
        #expect(f.waitUntilDisconnected())
        try assertFixtureHasNoSecrets(f)
    }

    @Test func partialPublicKeyAuthenticationContinuesWithOTPOnEveryEndpoint() throws {
        let resources = authenticationResources(); defer { #expect(authenticationResources().subtracting(resources).isEmpty) }
        let f = try JumpSSHFixture(targetMode: "keyOTP", jumpModes: ["keyOTP", "keyOTP"])
        defer { f.stop() }; try f.trustAll()
        let requests = InteractiveRequests()
        let provider = SFTPProvider(connection: f.connection, knownHostsURL: f.store.url) { challenge in
            requests.append(challenge); try? challenge.respond(f.otp)
        }
        #expect(try provider.list(path: "/", cancellation: TransferCancellation()).contains { $0.name == "hello.txt" })
        #expect(requests.values.map(\.endpoint.jumpHostIndex) == [0, 1, nil])
        for name in ["jump1", "jump2", "target"] {
            // OpenSSH may send signed proof directly without a separate offer.
            #expect(f.counter(name, "publickey") >= 1)
            #expect(f.counter(name, "interactive") == 1)
            #expect(f.counter(name, "response") == 1)
            #expect(f.counter(name, "accepted") == 1)
            #expect(f.counter(name, "password") == 0)
        }
        #expect(requests.allFinished)
        provider.closeConnection()
        #expect(f.waitUntilDisconnected())
    }

    @Test func interactiveChallengesNeverPrecedeTrustForAnyEndpoint() throws {
        let resources = authenticationResources(); defer { #expect(authenticationResources().subtracting(resources).isEmpty) }
        for changed in [false, true] {
            for index in 0..<3 {
                let f = try JumpSSHFixture(targetMode: "interactive", jumpModes: ["interactive", "interactive"])
                defer { f.stop() }
                let names = ["jump1", "jump2", "target"]
                for prior in names.prefix(index) { try f.store.trust(f.key(prior)) }
                if changed {
                    let expected = f.key(names[index]), other = f.key(names[(index + 1) % 3])
                    try f.store.trust(SFTPHostKey(host: expected.host, port: expected.port, keyType: other.keyType, publicKey: other.publicKey))
                }
                let requests = InteractiveRequests()
                let provider = SFTPProvider(connection: f.connection, knownHostsURL: f.store.url) { challenge in
                    requests.append(challenge); try? challenge.respond(fixtureAnswer(challenge, fixture: f))
                }
                let expected: SFTPError = changed ? .changedHostKey : .unknownHostKey
                do {
                    _ = try provider.list(path: "/", cancellation: TransferCancellation())
                    Issue.record("Untrusted MFA endpoint accepted")
                } catch let error as SFTPJumpHostError {
                    #expect(index < 2 && error.index == index && error.error == expected)
                } catch let error as SFTPError {
                    #expect(index == 2 && error == expected)
                }
                #expect(f.counter(names[index], "interactive") == 0)
                #expect(!requests.values.contains { $0.endpoint.jumpHostIndex == (index < 2 ? index : nil) })
                #expect(requests.allFinished)
                provider.closeConnection()
                #expect(f.waitUntilDisconnected())
            }
        }
    }

    @Test func wrongOTPReturnsAuthenticationFailureWithoutCredentialDiagnostics() throws {
        let resources = authenticationResources(); defer { #expect(authenticationResources().subtracting(resources).isEmpty) }
        let f = try JumpSSHFixture(targetMode: "interactive"); defer { f.stop() }; try f.trustAll()
        let wrong = "wrong-OTP-秘密-$(literal)"
        let requests = InteractiveRequests()
        let provider = SFTPProvider(connection: f.connection, knownHostsURL: f.store.url) { challenge in
            requests.append(challenge)
            try? challenge.respond(challenge.prompt.contains("Password:") ? f.password : wrong)
        }
        do {
            _ = try provider.list(path: "/", cancellation: TransferCancellation())
            Issue.record("Incorrect OTP authenticated")
        } catch {
            #expect(error as? SFTPError == .authenticationFailed)
            for secret in [wrong, f.password, f.otp, f.confirmation] { #expect(!error.localizedDescription.contains(secret)) }
            #expect(!error.localizedDescription.contains(f.root.path))
        }
        #expect(f.counter("target", "accepted") == 0)
        #expect(f.counter("target", "rejected") >= 1)
        #expect(requests.allFinished)
        provider.closeConnection()
        #expect(f.waitUntilDisconnected())
        try assertFixtureHasNoSecrets(f, additional: [wrong])
    }

    @Test func pendingTargetAndJumpChallengesCloseOnCancellationRejectionAndTimeout() throws {
        let resources = authenticationResources(); defer { #expect(authenticationResources().subtracting(resources).isEmpty) }
        for atJump in [false, true] {
            for action in ["cancel", "reject", "timeout"] {
                let f = try JumpSSHFixture(targetMode: "interactive", jumpModes: ["publickey", atJump ? "interactive" : "publickey"])
                defer { f.stop() }; try f.trustAll()
                var connection = f.connection; connection.timeoutSeconds = action == "timeout" ? 1.5 : 5
                let cancellation = TransferCancellation(), requests = InteractiveRequests()
                let provider = SFTPProvider(connection: connection, knownHostsURL: f.store.url) { challenge in
                    requests.append(challenge)
                    if action == "reject" { try? challenge.respond(nil) }
                    if action == "cancel" { cancellation.cancel() }
                }
                let started = ProcessInfo.processInfo.systemUptime
                #expect(throws: action == "timeout" ? SFTPError.timedOut : .cancelled) {
                    _ = try provider.list(path: "/", cancellation: cancellation)
                }
                #expect(ProcessInfo.processInfo.systemUptime - started < 5)
                #expect(requests.values.count == 1)
                if let challenge = requests.values.first {
                    #expect(challenge.endpoint.jumpHostIndex == (atJump ? 1 : nil))
                    #expect(!challenge.isPending)
                    #expect(throws: SFTPError.cancelled) { try challenge.respond("late answer") }
                }
                #expect(requests.allFinished)
                #expect(f.counter(atJump ? "jump2" : "target", "response") == 0)
                provider.closeConnection()
                #expect(f.waitUntilDisconnected())
                #expect(authenticationResources().subtracting(resources).isEmpty)
            }
        }
    }

    @Test func endlesslyRepeatedMFAChallengesStopAtBoundedLimit() throws {
        let resources = authenticationResources(); defer { #expect(authenticationResources().subtracting(resources).isEmpty) }
        let f = try JumpSSHFixture(targetMode: "endless"); defer { f.stop() }; try f.trustAll()
        let requests = InteractiveRequests()
        let provider = SFTPProvider(connection: f.connection, knownHostsURL: f.store.url) { challenge in
            requests.append(challenge); try? challenge.respond("synthetic-loop-answer")
        }
        do {
            _ = try provider.list(path: "/", cancellation: TransferCancellation())
            Issue.record("Endless MFA exchange authenticated")
        } catch let error as SFTPError {
            guard case .unsupported = error else { Issue.record("Unexpected challenge limit error: \(error)"); return }
        }
        #expect(requests.values.count == 16)
        #expect(f.counter("target", "response") == 16)
        #expect(f.counter("target", "accepted") == 0)
        #expect(requests.allFinished)
        provider.closeConnection()
        #expect(f.waitUntilDisconnected())
    }

    @Test func cancelledUploadCleanupNeverReopensTargetOrJumpAuthentication() throws {
        let resources = authenticationResources(); defer { #expect(authenticationResources().subtracting(resources).isEmpty) }
        for atJump in [false, true] {
            let f = try JumpSSHFixture(targetMode: atJump ? "password" : "interactive", jumpModes: ["publickey", atJump ? "interactive" : "publickey"])
            defer { f.stop() }; try f.trustAll()
            let requests = InteractiveRequests(), cancellation = TransferCancellation()
            let source = f.root.appendingPathComponent("cancelled-upload-source")
            try Data("Synthetic cancelled upload".utf8).write(to: source)
            let provider = SFTPProvider(connection: f.connection, password: f.password, knownHostsURL: f.store.url) { challenge in
                requests.append(challenge); try? challenge.respond(fixtureAnswer(challenge, fixture: f))
            }
            // The initial progress callback follows successful creation of the
            // temporary remote file and therefore exercises reconnect cleanup.
            #expect(throws: SFTPError.cancelled) {
                try provider.upload(from: source, to: "/cancelled.txt", cancellation: cancellation) { _ in cancellation.cancel() }
            }
            #expect(requests.values.count == 3)
            #expect(requests.values.allSatisfy { $0.endpoint.jumpHostIndex == (atJump ? 1 : nil) })
            #expect(requests.allFinished)
            #expect(f.counter(atJump ? "jump2" : "target", "interactive") == 1)
            #expect(f.counter(atJump ? "jump2" : "target", "response") == 2)
            provider.closeConnection()
            #expect(f.waitUntilDisconnected())
            #expect(authenticationResources().subtracting(resources).isEmpty)
        }
    }
}

private final class InteractiveRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SFTPAuthenticationChallenge] = []
    private var finished = 0
    var values: [SFTPAuthenticationChallenge] { lock.lock(); defer { lock.unlock() }; return requests }
    var allFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished == requests.count && requests.allSatisfy { !$0.isPending } }
    func append(_ challenge: SFTPAuthenticationChallenge) {
        lock.lock(); requests.append(challenge); lock.unlock()
        challenge.whenFinished { [self] in lock.lock(); finished += 1; lock.unlock() }
    }
}

private func fixtureAnswer(_ challenge: SFTPAuthenticationChallenge, fixture: JumpSSHFixture) -> String {
    if challenge.prompt.contains("Verification code:") { return fixture.otp }
    if challenge.prompt.contains("Confirmation code:") { return fixture.confirmation }
    return challenge.endpoint.jumpHostIndex.map { fixture.jumpPasswords[$0] } ?? fixture.password
}

private func authenticationResources() -> Set<String> {
    var result = Set<String>()
    for root in [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/private/tmp")] {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            if name.hasPrefix("farmac-askpass-") || name.hasPrefix("farmac-interactive-") || (name.hasPrefix("farmac-jump-") && !name.hasPrefix("farmac-jump-test-")) {
                result.insert(root.appendingPathComponent(name).path)
            }
        }
    }
    return result
}

private func assertFixtureHasNoSecrets(_ fixture: JumpSSHFixture, additional: [String] = []) throws {
    let secrets = [fixture.password, fixture.otp, fixture.confirmation] + fixture.jumpPasswords + additional
    // Credentials enter Python on stdin. Only synthetic private keys, public
    // host keys, protocol counters and transferred files may be persisted.
    for name in ["startup.log", "stats.json", "known_hosts"] {
        let text = try String(contentsOf: fixture.root.appendingPathComponent(name), encoding: .utf8)
        for secret in secrets { #expect(!text.contains(secret)) }
    }
}
