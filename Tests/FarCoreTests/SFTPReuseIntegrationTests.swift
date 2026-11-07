import Foundation
import Darwin
import Testing
@testable import FarCore

extension SFTPPasswordTests {
    @Test func authenticatedMFAConnectionAndBothJumpHostsAreReusedForFileOperations() throws {
        let f = try JumpSSHFixture(targetMode: "interactive", jumpModes: ["interactive", "interactive"])
        defer { f.stop() }; try f.trustAll()
        let prompts = ReusePrompts()
        let p = reuseProvider(f, prompts: prompts); defer { p.closeConnection() }
        let oldToken = TransferCancellation()
        #expect(try p.list(path: "/", cancellation: oldToken).contains { $0.name == "hello.txt" })
        // A completed request's cancellation must never poison the idle transport.
        oldToken.cancel()
        let token = TransferCancellation()
        #expect(try p.stat(path: "/missing", cancellation: token) == nil)
        #expect(throws: (any Error).self) { try p.remove(path: "/missing", isDirectory: false, cancellation: token) }
        let source = f.root.appendingPathComponent("reuse-source")
        let bytes = Data("reused SSH and MFA — Привет".utf8)
        try bytes.write(to: source)
        try p.upload(from: source, to: "/reused.txt", cancellation: token) { _ in }
        try p.rename(from: "/reused.txt", to: "/renamed.txt", replace: false, cancellation: token)
        let destination = f.root.appendingPathComponent("reuse-downloaded")
        try p.download(path: "/renamed.txt", to: destination, resumeOffset: 0, cancellation: token) { _ in }
        #expect(try Data(contentsOf: destination) == bytes)
        try p.remove(path: "/renamed.txt", isDirectory: false, cancellation: token)
        #expect(prompts.count == 9)
        for endpoint in ["jump1", "jump2", "target"] {
            #expect(f.counter(endpoint, "interactive") == 1)
            #expect(f.counter(endpoint, "accepted") == 1)
            #expect(f.counter(endpoint, "active") == 1)
        }
        // Exactly one downstream transport travels through each tunnel.
        #expect(f.counter("jump1", "forward") == 1)
        #expect(f.counter("jump2", "forward") == 1)
        p.closeConnection(); p.closeConnection()
        #expect(f.waitUntilDisconnected())
    }

    @Test func reuseIsIsolatedPerProviderAndExplicitDisconnectRequiresFreshMFA() throws {
        let f = try JumpSSHFixture(targetMode: "interactive"); defer { f.stop() }; try f.trustAll()
        let firstPrompts = ReusePrompts(), secondPrompts = ReusePrompts()
        let first = reuseProvider(f, prompts: firstPrompts), second = reuseProvider(f, prompts: secondPrompts)
        defer { first.closeConnection(); second.closeConnection() }
        #expect(try first.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        #expect(try second.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        #expect(firstPrompts.count == 3 && secondPrompts.count == 3)
        #expect(f.counter("target", "interactive") == 2)
        first.closeConnection()
        #expect(try first.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        #expect(firstPrompts.count == 6 && secondPrompts.count == 3)
        #expect(f.counter("target", "interactive") == 3)
        // The other profile instance keeps its own authenticated session.
        #expect(try second.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        #expect(f.counter("target", "interactive") == 3)
    }

    @Test func changedTrustInvalidatesAuthenticatedTransportBeforeAnyNewSecret() throws {
        let f = try JumpSSHFixture(targetMode: "interactive", jumpModes: ["interactive", "interactive"])
        defer { f.stop() }; try f.trustAll()
        let p = reuseProvider(f, prompts: ReusePrompts())
        defer { p.closeConnection() }
        #expect(try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        let jump = f.key("jump1"), other = f.key("target")
        try f.store.trust(SFTPHostKey(host: jump.host, port: jump.port, keyType: other.keyType, publicKey: other.publicKey))
        do {
            _ = try p.list(path: "/", cancellation: TransferCancellation())
            Issue.record("Cached authentication bypassed changed jump trust")
        } catch let failure as SFTPJumpHostError {
            #expect(failure.index == 0 && failure.error == .changedHostKey)
        }
        #expect(f.counter("jump1", "interactive") == 1)
        #expect(f.counter("target", "interactive") == 1)
        #expect(f.waitUntilDisconnected())
        try f.store.trust(jump)
        #expect(try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        #expect(f.counter("jump1", "interactive") == 2)
        #expect(f.counter("target", "interactive") == 2)
    }

    @Test func cancelledActiveRequestClosesCachedRouteAndReconnectsOnlyOnNextCommand() throws {
        let f = try JumpSSHFixture(targetMode: "interactive", jumpModes: ["interactive", "interactive"])
        defer { f.stop() }; try f.trustAll()
        let p = reuseProvider(f, prompts: ReusePrompts())
        defer { p.closeConnection() }
        let token = TransferCancellation()
        #expect(try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        let destination = f.root.appendingPathComponent("cancelled-reuse")
        #expect(throws: SFTPError.cancelled) {
            try p.download(path: "/hello.txt", to: destination, resumeOffset: 0, cancellation: token) { _ in token.cancel() }
        }
        #expect(f.waitUntilDisconnected())
        for endpoint in ["jump1", "jump2", "target"] { #expect(f.counter(endpoint, "interactive") == 1) }
        #expect(try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        for endpoint in ["jump1", "jump2", "target"] { #expect(f.counter(endpoint, "interactive") == 2) }
    }

    @Test func concurrentWaitCancellationAndCallbackReentryDoNotPoisonActiveSession() throws {
        let f = try JumpSSHFixture(targetMode: "interactive"); defer { f.stop() }; try f.trustAll()
        let p = reuseProvider(f, prompts: ReusePrompts())
        defer { p.closeConnection() }
        #expect(try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        let state = ReuseWorker(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try p.download(path: "/hello.txt", to: f.root.appendingPathComponent("parallel-download"), resumeOffset: 0,
                               cancellation: TransferCancellation()) { progress in
                    if progress.completedBytes == 0 {
                        // Reentering a synchronous provider from its own callback
                        // fails immediately rather than waiting on itself.
                        do { _ = try p.stat(path: "/hello.txt", cancellation: TransferCancellation()); state.record("Reentry succeeded") }
                        catch SFTPError.unsupported { }
                        catch { state.record("Unexpected reentry error: \(error)") }
                        entered.signal(); _ = release.wait(timeout: .now() + 5)
                    }
                }
            } catch { state.record("Active download: \(error)") }
            state.done.signal()
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        let waiting = TransferCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { waiting.cancel() }
        #expect(throws: SFTPError.cancelled) { _ = try p.list(path: "/", cancellation: waiting) }
        let queued = ReuseWorker()
        DispatchQueue.global().async {
            do { _ = try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) }
            catch { queued.record("Queued request: \(error)") }
            queued.done.signal()
        }
        release.signal()
        #expect(queued.done.wait(timeout: .now() + 5) == .success)
        #expect(queued.errors.isEmpty)
        #expect(state.done.wait(timeout: .now() + 5) == .success)
        #expect(state.errors.isEmpty)
        #expect(try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        #expect(f.counter("target", "interactive") == 1)
    }

    @Test func waitingTimeoutAndDisconnectDuringProgressLeaveNoSessionOrStaleWaiter() throws {
        let f = try JumpSSHFixture(); defer { f.stop() }; try f.trustAll()
        var connection = f.connection; connection.timeoutSeconds = 1.5
        let p = SFTPProvider(connection: connection, password: f.password, knownHostsURL: f.store.url)
        defer { p.closeConnection() }
        let worker = ReuseWorker(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try p.download(path: "/hello.txt", to: f.root.appendingPathComponent("waiting-timeout"), resumeOffset: 0,
                               cancellation: TransferCancellation()) { progress in
                    if progress.completedBytes == 0 { entered.signal(); _ = release.wait(timeout: .now() + 5) }
                }
            } catch { worker.record("Active download: \(error)") }
            worker.done.signal()
        }
        #expect(entered.wait(timeout: .now() + 5) == .success)
        #expect(throws: SFTPError.timedOut) { _ = try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) }
        release.signal()
        #expect(worker.done.wait(timeout: .now() + 5) == .success)
        #expect(worker.errors.isEmpty)
        #expect(f.counter("target", "password") == 1)
        // Synchronous close from the callback only invalidates/cancels; it must
        // not wait on the operation whose callback is currently executing.
        #expect(throws: SFTPError.cancelled) {
            try p.download(path: "/hello.txt", to: f.root.appendingPathComponent("disconnect-progress"), resumeOffset: 0,
                           cancellation: TransferCancellation()) { _ in p.closeConnection() }
        }
        #expect(f.waitUntilDisconnected())
        #expect(try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        #expect(f.counter("target", "password") == 2)
    }

    @Test func idleRequestDeadlineResetsAndTimeoutInvalidatesOnlyActiveTransport() throws {
        let f = try JumpSSHFixture(); defer { f.stop() }
        // Exercise request deadlines on the real target without spending the
        // same short budget on two unrelated gateway handshakes.
        var connection = f.connection
        connection.timeoutSeconds = 1.5
        connection.sftpJumpHosts = []
        connection.host = "127.0.0.1"
        let target = f.key("target")
        try f.store.trust(SFTPHostKey(host: connection.host, port: connection.port, keyType: target.keyType, publicKey: target.publicKey))
        let p = SFTPProvider(connection: connection, password: f.password, knownHostsURL: f.store.url)
        defer { p.closeConnection() }
        #expect(try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        Thread.sleep(forTimeInterval: 1.6)
        #expect(try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        #expect(f.counter("target", "password") == 1)
        // Delay only the next server operation, after successful authentication.
        try "2".write(to: f.root.appendingPathComponent("request-delay"), atomically: true, encoding: .utf8)
        #expect(throws: SFTPError.timedOut) { _ = try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) }
        #expect(f.waitUntilDisconnected())
        #expect(f.counter("target", "password") == 1)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("request-delay"))
        #expect(try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        #expect(f.counter("target", "password") == 2)
    }

    @Test func serverDisconnectDoesNotRetryAmbiguousWriteAndNextCommandReconnects() throws {
        let f = try JumpSSHFixture(); defer { f.stop() }; try f.trustAll()
        let p = f.provider; defer { p.closeConnection() }
        #expect(try p.stat(path: "/hello.txt", cancellation: TransferCancellation()) != nil)
        let source = f.root.appendingPathComponent("ambiguous-source")
        try Data("published once".utf8).write(to: source)
        try Data().write(to: f.root.appendingPathComponent("disconnect-after-rename"))
        #expect(throws: (any Error).self) { try p.upload(from: source, to: "/published.txt", cancellation: TransferCancellation()) { _ in } }
        #expect(f.waitUntilDisconnected())
        #expect(f.counter("target", "password") == 1)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("files/published.txt")) == Data("published once".utf8))
        #expect(f.counter("target", "rename") == 1)
        #expect(try p.stat(path: "/published.txt", cancellation: TransferCancellation()) != nil)
        #expect(f.counter("target", "password") == 2)
        #expect(f.counter("target", "rename") == 1)
    }
}

private final class ReusePrompts {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func append() { lock.lock(); value += 1; lock.unlock() }
}
private func reuseProvider(_ fixture: JumpSSHFixture, prompts: ReusePrompts) -> SFTPProvider {
    SFTPProvider(connection: fixture.connection, password: fixture.password, knownHostsURL: fixture.store.url) { challenge in
        prompts.append()
        let answer = challenge.prompt.contains("Verification code:") ? fixture.otp : challenge.prompt.contains("Confirmation code:") ? fixture.confirmation : challenge.endpoint.jumpHostIndex.map { fixture.jumpPasswords[$0] } ?? fixture.password
        try? challenge.respond(answer)
    }
}
private final class ReuseWorker {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var failures: [String] = []
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return failures }
    func record(_ text: String) { lock.lock(); failures.append(text); lock.unlock() }
}
