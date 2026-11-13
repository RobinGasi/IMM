import AppKit
import Foundation

public enum LockReason: Equatable, Sendable {
    case inactivity(minutes: Int)
    case sleep
    case manual
}

/// Decides when the app must lock: idle time without input inside IMM, and system sleep / screen lock events.
/// After it reports a reason it stops itself; call `start()` again after the next unlock.
@MainActor
public final class LockMonitor {
    /// `nil` = never lock on inactivity.
    public var autoLockMinutes: Int?
    public var lockOnSleep: Bool
    public var onLock: (@MainActor (LockReason) -> Void)?

    private let now: @MainActor () -> ContinuousClock.Instant
    private var lastActivity: ContinuousClock.Instant
    private var fired = false
    private var running = false
    private var eventMonitor: Any?
    private var timer: Timer?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    public init(
        autoLockMinutes: Int? = 5,
        lockOnSleep: Bool = true,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        onLock: (@MainActor (LockReason) -> Void)? = nil
    ) {
        self.autoLockMinutes = autoLockMinutes
        self.lockOnSleep = lockOnSleep
        self.now = now
        self.onLock = onLock
        self.lastActivity = now()
    }

    public func start() {
        guard !running else { return }
        running = true
        fired = false
        lastActivity = now()

        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.noteActivity() }
            return event
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(name, on: workspace)
        }
        observe(Notification.Name("com.apple.screenIsLocked"), on: DistributedNotificationCenter.default())
    }

    public func stop() {
        running = false
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        timer?.invalidate()
        timer = nil
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemSleepEvent() }
        }
        observers.append((center, token))
    }

    /// Records user input inside IMM.
    public func noteActivity() {
        lastActivity = now()
    }

    /// Fires `.inactivity` when the idle time has reached the limit. Driven by a 1 s timer; callable directly.
    public func checkIdle() {
        guard !fired, let minutes = autoLockMinutes, minutes > 0 else { return }
        if now() - lastActivity >= .seconds(minutes * 60) {
            fire(.inactivity(minutes: minutes))
        }
    }

    /// Sleep, display sleep, screen lock or fast user switching.
    func systemSleepEvent() {
        guard lockOnSleep else { return }
        fire(.sleep)
    }

    private func fire(_ reason: LockReason) {
        guard !fired else { return }
        fired = true
        stop()
        onLock?(reason)
    }
}
