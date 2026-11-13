import Foundation
@testable import IMMSyncCore
import Testing

struct AwakeClockTests {
    @Test func runningTimeCounts() {
        let start = ContinuousClock.now
        let clock = AwakeClock(tolerance: .seconds(1), now: start)
        clock.observe(at: start.advanced(by: .milliseconds(50)))
        clock.observe(at: start.advanced(by: .milliseconds(100)))
        #expect(clock.elapsed == .milliseconds(100))
    }

    /// The failure this exists for: a Mac that sleeps (or a process that is frozen) in the middle of a 20 s run limit.
    /// `ContinuousClock` counts the whole gap, so the limit expired the moment the Mac woke up.
    @Test func aGapLongerThanTheToleranceIsNotRunningTime() {
        let start = ContinuousClock.now
        let clock = AwakeClock(tolerance: .seconds(1), now: start)
        clock.observe(at: start.advanced(by: .milliseconds(50)))
        clock.observe(at: start.advanced(by: .seconds(3600)))   // the Mac slept for an hour
        clock.observe(at: start.advanced(by: .seconds(3600) + .milliseconds(50)))
        #expect(clock.elapsed < .seconds(2))
        #expect(clock.elapsed >= .milliseconds(100))
    }

    @Test func staleObservationsAreIgnored() {
        let start = ContinuousClock.now
        let clock = AwakeClock(now: start)
        clock.observe(at: start.advanced(by: .milliseconds(200)))
        clock.observe(at: start.advanced(by: .milliseconds(100)))
        #expect(clock.elapsed == .milliseconds(200))
    }

    @Test func sleepWaitsAtLeastTheAwakeDuration() async throws {
        let begun = ContinuousClock.now
        try await AwakeClock.sleep(for: .milliseconds(250))
        #expect(ContinuousClock.now - begun >= .milliseconds(250))
    }

    @Test func sleepEndsWhenCancelled() async {
        let task = Task { try await AwakeClock.sleep(for: .seconds(60)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
