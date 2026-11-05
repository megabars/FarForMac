import Foundation
import Darwin

/// Cooperative budget for synchronous matching on the current thread. Time spent
/// descheduled must not turn a valid match into a timeout on a busy machine.
/// Keep construction and checks on the same thread; this is not an async deadline.
struct MatchingTimeBudget {
    private let clock: clockid_t
    private let start: TimeInterval
    private let limit: TimeInterval

    init(seconds: TimeInterval) {
        precondition(seconds.isFinite && seconds > 0)
        var value = timespec()
        if clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0 {
            clock = CLOCK_THREAD_CPUTIME_ID
        } else {
            clock = CLOCK_MONOTONIC
            clock_gettime(clock, &value)
        }
        start = Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
        limit = seconds
    }

    var expired: Bool {
        var value = timespec()
        guard clock_gettime(clock, &value) == 0 else { return true }
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000 - start >= limit
    }
}
