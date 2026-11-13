import Foundation

/// Elapsed time that does not count the stretches in which this process could not run (system sleep, a frozen or starved
/// process): `ContinuousClock` and `Task.sleep(for:)` keep counting through those, so a 20-second run limit expires the moment
/// the Mac wakes up, however briefly the session had been waiting.
///
/// The clock is advanced by `observe`, called often (a 50 ms tick, a 100 ms sleep step). Each observation adds the time since
/// the previous one, but at most `tolerance`: a longer gap means nobody was scheduled to observe, and the excess is dropped.
public final class AwakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private let tolerance: Duration
    private var last: ContinuousClock.Instant
    private var total: Duration = .zero

    /// - Parameter tolerance: the longest gap between two observations that still counts as running time. Must exceed the
    ///   observation period by a wide margin (scheduling jitter under load), yet stay short against the timeouts it guards.
    public init(tolerance: Duration = .seconds(1), now: ContinuousClock.Instant = .now) {
        self.tolerance = tolerance
        self.last = now
    }

    /// Awake time up to the latest observation.
    public var elapsed: Duration { lock.withLock { total } }

    /// Records that it is `now` and returns the awake time so far. An observation older than the previous one is ignored.
    @discardableResult
    public func observe(at now: ContinuousClock.Instant = .now) -> Duration {
        lock.withLock {
            if now > last {
                total += min(now - last, tolerance)
                last = now
            }
            return total
        }
    }

    /// Sleeps for `duration` of awake time (a sleep of the Mac or a frozen process does not shorten it).
    public static func sleep(for duration: Duration, step: Duration = .milliseconds(100)) async throws {
        let clock = AwakeClock()
        while clock.elapsed < duration {
            try await Task.sleep(for: min(step, duration - clock.elapsed))
            clock.observe()
        }
    }
}
