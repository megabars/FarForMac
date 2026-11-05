import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite struct ProcessControlTests {
    @Test func rejectsReusedIdentityAndOwnProcessMutation() throws {
        let current = try ProcessControl.identity(pid: getpid())
        try ProcessControl.verify(current)
        let stale = ProcessIdentity(pid: current.pid, startSeconds: current.startSeconds + 1,
                                    startMicroseconds: current.startMicroseconds, userID: current.userID)
        #expect(throws: (any Error).self) { try ProcessControl.verify(stale) }
        #expect(throws: (any Error).self) { try ProcessControl.terminate(current) }
        #expect(throws: (any Error).self) { try ProcessControl.identity(pid: 0) }
    }
    @Test func terminatesOnlyCapturedFixtureChild() throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let identity = try ProcessControl.identity(pid: child.processIdentifier)
        let nice = try ProcessControl.priority(identity)
        try ProcessControl.changePriority(identity, increase: false)
        #expect(try ProcessControl.priority(identity) == min(20, nice + 1))
        try ProcessControl.terminate(identity)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(throws: (any Error).self) { try ProcessControl.verify(identity) }
    }
}

