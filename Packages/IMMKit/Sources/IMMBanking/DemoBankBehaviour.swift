import Foundation

/// In-memory switches for the demo bank. The Debug menu flips them; nothing is persisted.
public final class DemoBankBehaviour: @unchecked Sendable {
    public enum SyncMode: Sendable, Equatable, CaseIterable {
        case succeeds
        case fails
    }

    public enum ApprovalMode: Sendable, Equatable, CaseIterable {
        case approves
        case expires
    }

    /// The instance used by the app and the Debug menu.
    public static let shared = DemoBankBehaviour()

    private let lock = NSLock()
    private var syncMode: SyncMode
    private var approvalMode: ApprovalMode

    public init(sync: SyncMode = .succeeds, approval: ApprovalMode = .approves) {
        self.syncMode = sync
        self.approvalMode = approval
    }

    public var sync: SyncMode {
        get { lock.withLock { syncMode } }
        set { lock.withLock { syncMode = newValue } }
    }

    public var approval: ApprovalMode {
        get { lock.withLock { approvalMode } }
        set { lock.withLock { approvalMode = newValue } }
    }
}
