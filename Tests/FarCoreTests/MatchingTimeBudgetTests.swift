import Foundation
import Testing
@testable import FarCore

struct MatchingTimeBudgetTests {
    @Test func waitingDoesNotConsumeMatchingCPUTime() {
        let budget = MatchingTimeBudget(seconds: 0.04)
        Thread.sleep(forTimeInterval: 0.12)
        #expect(!budget.expired)
    }

    @Test func CPUWorkStillExhaustsTheBudget() {
        let budget = MatchingTimeBudget(seconds: 0.002)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !budget.expired && ProcessInfo.processInfo.systemUptime < deadline {}
        #expect(budget.expired)
    }
}
