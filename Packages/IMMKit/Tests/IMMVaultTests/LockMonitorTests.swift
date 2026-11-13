import Foundation
import Testing
@testable import IMMVault

@MainActor
private func makeFixture(minutes: Int?, lockOnSleep: Bool = true) -> (LockMonitor, ClockBox, ReasonLog) {
    let clock = ClockBox()
    let log = ReasonLog()
    let monitor = LockMonitor(
        autoLockMinutes: minutes, lockOnSleep: lockOnSleep,
        now: { clock.instant },
        onLock: { log.reasons.append($0) }
    )
    return (monitor, clock, log)
}

@MainActor private final class ClockBox {
    var instant = ContinuousClock.now
    func advance(seconds: Int) { instant = instant + .seconds(seconds) }
}

@MainActor private final class ReasonLog {
    var reasons: [LockReason] = []
}

@MainActor
@Suite struct LockMonitorTests {
    @Test func locksAfterConfiguredInactivity() {
        let (monitor, clock, log) = makeFixture(minutes: 5)
        clock.advance(seconds: 299)
        monitor.checkIdle()
        #expect(log.reasons.isEmpty)

        clock.advance(seconds: 1)
        monitor.checkIdle()
        #expect(log.reasons == [.inactivity(minutes: 5)])

        // Reports once.
        clock.advance(seconds: 600)
        monitor.checkIdle()
        #expect(log.reasons.count == 1)
    }

    @Test func activityResetsTheIdleTimer() {
        let (monitor, clock, log) = makeFixture(minutes: 1)
        clock.advance(seconds: 50)
        monitor.noteActivity()
        clock.advance(seconds: 50)
        monitor.checkIdle()
        #expect(log.reasons.isEmpty)
        clock.advance(seconds: 10)
        monitor.checkIdle()
        #expect(log.reasons == [.inactivity(minutes: 1)])
    }

    @Test func neverMeansNever() {
        let (monitor, clock, log) = makeFixture(minutes: nil)
        clock.advance(seconds: 60 * 60 * 24)
        monitor.checkIdle()
        #expect(log.reasons.isEmpty)
    }

    @Test func limitChangesApplyImmediately() {
        let (monitor, clock, log) = makeFixture(minutes: 60)
        clock.advance(seconds: 120)
        monitor.checkIdle()
        #expect(log.reasons.isEmpty)
        monitor.autoLockMinutes = 1
        monitor.checkIdle()
        #expect(log.reasons == [.inactivity(minutes: 1)])
    }

    @Test func sleepLocksWhenEnabled() {
        let (monitor, _, log) = makeFixture(minutes: nil, lockOnSleep: true)
        monitor.systemSleepEvent()
        monitor.systemSleepEvent()
        #expect(log.reasons == [.sleep])
    }

    @Test func sleepIgnoredWhenDisabled() {
        let (monitor, _, log) = makeFixture(minutes: nil, lockOnSleep: false)
        monitor.systemSleepEvent()
        #expect(log.reasons.isEmpty)
        monitor.lockOnSleep = true
        monitor.systemSleepEvent()
        #expect(log.reasons == [.sleep])
    }
}
