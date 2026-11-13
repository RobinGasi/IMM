import Foundation
import GRDB
import IMMLedger
import IMMSyncCore
import Observation
import Security

public enum SyncStatus: Equatable, Sendable {
    case off
    /// Turned on, but the user has not yet allowed the helper in System Settings › Login Items.
    case needsApproval
    case noTailscale
    /// The agent listens on the tailnet; `host` is the MagicDNS name when it resolves, else the 100.x address.
    case listening(host: String)
    case error(String)
}

public struct SyncDeviceInfo: Identifiable, Equatable, Sendable {
    public var id: DeviceNodeID
    public var name: String
    public var lastSeen: Date?
    public var lastSync: Date?
    /// "Tailscale" (the only route today).
    public var route: String
    public var isConnected: Bool
}

public enum SyncPairingPhase: Equatable, Sendable {
    case idle
    /// QR and code are shown; nobody connected yet.
    case offering(PairingOffer)
    /// A device connected: both screens show `code`; the user confirms on the Mac.
    case confirming(deviceName: String?, code: ShortAuthCode)
}

/// Launch-argument switches for development builds (`-IMMSyncEnable`, `-IMMSyncPrintPairingCode`, `-IMMSyncAutoConfirm`,
/// `-IMMSyncDebugEdit`, `-IMMSyncDumpOnChange`). Only `App/IMMApp.swift` creates one, inside `#if DEBUG`.
public struct SyncDebugOptions: Sendable {
    public var enable = false
    public var printPairingCode = false
    public var autoConfirm = false
    public var debugEdit = false
    public var dumpOnChange = false
    /// Turn sync off for the opened vault and unregister the agent (cleanup after a test run).
    public var disable = false

    public init(
        enable: Bool = false, printPairingCode: Bool = false, autoConfirm: Bool = false, debugEdit: Bool = false, dumpOnChange: Bool = false,
        disable: Bool = false
    ) {
        self.disable = disable
        self.enable = enable
        self.printPairingCode = printPairingCode
        self.autoConfirm = autoConfirm
        self.debugEdit = debugEdit
        self.dumpOnChange = dumpOnChange
    }

    public init(defaults: UserDefaults) {
        self.init(
            enable: defaults.bool(forKey: "IMMSyncEnable"), printPairingCode: defaults.bool(forKey: "IMMSyncPrintPairingCode"),
            autoConfirm: defaults.bool(forKey: "IMMSyncAutoConfirm"), debugEdit: defaults.bool(forKey: "IMMSyncDebugEdit"),
            dumpOnChange: defaults.bool(forKey: "IMMSyncDumpOnChange"), disable: defaults.bool(forKey: "IMMSyncDisable"))
    }
}

private extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Sync over Tailscale for the unlocked app: switch, status, devices, pairing, removal. Owns the SMAppService registration of the
/// agent and, while a vault is unlocked and the switch is on, a `SyncCoordinator` that talks to the agent.
///
/// Lifecycle: `start(ledger:vaultID:)` on unlock, `stop()` on lock (the agent then serves the mailbox on its own). The switch is
/// per database (`syncEnabled.<vaultID>` in the app's preferences); the agent registration is per user and follows the switch.
@MainActor @Observable
public final class SyncService {
    public private(set) var status: SyncStatus = .off
    public private(set) var devices: [SyncDeviceInfo] = []
    public private(set) var pairing: SyncPairingPhase = .idle
    /// The switch "Sync over Tailscale".
    public private(set) var isEnabled = false
    /// Last problem worth showing (batch refused, helper unreachable); cleared on the next successful start.
    public private(set) var lastError: String?
    /// State of the iCloud relay lane (the async lane for devices that are asleep, locked or offline).
    public private(set) var relayStatus: RelayStatus = .unavailable("Sync is off.")
    /// When the last op from another device was applied.
    public private(set) var lastRemoteChange: Date?
    /// Whether this build can run the helper (a signed build with the keychain entitlement; ad-hoc builds cannot use the group container).
    public var isAvailable: Bool { Self.hasSigningEntitlement }

    @ObservationIgnored public var debugOptions = SyncDebugOptions()

    @ObservationIgnored private let registrar: any AgentRegistrar
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeClient: @Sendable (any AgentAppEndpoint) -> AgentXPCClient
    @ObservationIgnored private let bundleVersion: String
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let resolveHost: @Sendable (String) async -> String
    @ObservationIgnored private let requiresSigning: Bool
    @ObservationIgnored private let publishDelay: Duration
    @ObservationIgnored private let relayProvider: any RelayProviding
    @ObservationIgnored private var ledger: LedgerStore?
    @ObservationIgnored private var vaultID: UUID?
    @ObservationIgnored private var coordinator: SyncCoordinator?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var debugTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var printedPairing = false
    @ObservationIgnored private var autoConfirmed: ShortAuthCode?
    @ObservationIgnored private var resolvedHosts: [String: String] = [:]

    public init(
        registrar: any AgentRegistrar = SMAppServiceRegistrar(),
        defaults: UserDefaults = .standard,
        makeClient: @escaping @Sendable (any AgentAppEndpoint) -> AgentXPCClient = { AgentXPCClient(endpoint: $0) },
        bundleVersion: String = SyncService.currentBuildIdentifier(),
        deviceName: String = Host.current().localizedName ?? "Mac",
        resolveHost: @escaping @Sendable (String) async -> String = { await MagicDNS.name(for: $0) },
        requiresSigning: Bool = true,
        publishDelay: Duration = .milliseconds(300), relay: any RelayProviding = CloudKitRelayProvider()
    ) {
        self.relayProvider = relay
        self.registrar = registrar
        self.defaults = defaults
        self.makeClient = makeClient
        self.bundleVersion = bundleVersion
        self.deviceName = deviceName
        self.resolveHost = resolveHost
        self.requiresSigning = requiresSigning
        self.publishDelay = publishDelay
    }

    /// `CFBundleVersion`, plus the modification time of the embedded agent executable: a rebuilt agent (development builds keep one
    /// `CFBundleVersion`) is a different binary to launchd's background-item check, so it needs a fresh registration too.
    public static func currentBuildIdentifier(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let agent = bundle.bundleURL.appendingPathComponent(AgentConstants.agentExecutablePath)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: agent.path))?[.modificationDate] as? Date else { return version }
        return "\(version).\(Int(modified.timeIntervalSince1970))"
    }

    static var hasSigningEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
    }

    private func enabledKey(_ id: UUID) -> String { "syncEnabled.\(id.uuidString)" }

    // MARK: Lifecycle

    /// The vault was unlocked. Starts syncing when the switch is on.
    public func start(ledger: LedgerStore, vaultID: UUID) {
        stop()
        RemoteNotificationRegistration.registerOnce()
        self.ledger = ledger
        self.vaultID = vaultID
        if debugOptions.enable { defaults.set(true, forKey: enabledKey(vaultID)) }
        isEnabled = defaults.bool(forKey: enabledKey(vaultID))
        if debugOptions.disable {
            Task { await setEnabled(false) }
        } else if isEnabled {
            launch()
        } else {
            status = .off
        }
    }

    /// The vault is about to lock: stops everything that works on the ledger, forgets it and tells the agent (which then serves the
    /// mailbox on its own). Returns when no step of the service is still running on the ledger, so the caller may close the vault
    /// right after: nothing new starts (`requestStop` is synchronous), steps already running are waited for, and steps that are
    /// suspended see the stop when they resume. It blocks the main actor for those running steps only (a few milliseconds; at most
    /// `drainLimit` when one hangs on the agent).
    public func stop() {
        generation += 1
        launchTask?.cancel()
        launchTask = nil
        debugTasks.forEach { $0.cancel() }
        debugTasks = []
        let old = coordinator
        old?.requestStop()
        coordinator = nil
        ledger = nil
        vaultID = nil
        devices = []
        pairing = .idle
        status = .off
        relayStatus = .unavailable("Sync is off.")
        printedPairing = false
        guard let old else { return }
        let drained = DispatchSemaphore(value: 0)
        // Detached: the coordinator's work does not need the main actor, which is blocked below.
        Task.detached {
            await old.quiesce(limit: Self.drainLimit)
            drained.signal()
        }
        _ = drained.wait(timeout: .now() + Self.drainLimit.timeInterval + 0.5)
        Task { await old.detach() }
    }

    /// How long `stop()` waits for a step that does not finish on its own.
    static let drainLimit: Duration = .milliseconds(800)

    /// The switch. Turning it on registers the agent (the user may have to allow it in Login Items) and attaches; turning it off
    /// detaches and unregisters the agent. Paired devices stay in the roster.
    public func setEnabled(_ on: Bool) async {
        guard let vaultID else { return }
        defaults.set(on, forKey: enabledKey(vaultID))
        isEnabled = on
        if on {
            launch()
        } else {
            generation += 1
            launchTask?.cancel()
            launchTask = nil
            debugTasks.forEach { $0.cancel() }
            debugTasks = []
            let old = coordinator
            coordinator = nil
            pairing = .idle
            status = .off
            relayStatus = .unavailable("Sync is off.")
            devices = []
            await old?.stop()
            // The agent serves every vault; unregister it only when no vault we know of wants it.
            let anyOn = defaults.dictionaryRepresentation().contains { $0.key.hasPrefix("syncEnabled.") && ($0.value as? Bool) == true }
            if !anyOn {
                try? await registrar.unregister()
                defaults.removeObject(forKey: "syncAgentRegisteredBuild")
            }
        }
    }

    public func openLoginItemsSettings() { registrar.openApprovalSettings() }

    private func launch() {
        guard let ledger else { return }
        generation += 1
        let token = generation
        lastError = nil
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            guard let self else { return }
            await self.run(ledger: ledger, token: token)
        }
    }

    private func run(ledger: LedgerStore, token: Int) async {
        func current() -> Bool { token == generation && !Task.isCancelled }
        if requiresSigning, !Self.hasSigningEntitlement {
            status = .error("Sync needs a signed build of IMM.")
            return
        }
        do {
            guard try await ensureRegistered(token: token) else { return }
            guard current() else { return }
            let engine = try SyncEngine(ledger: ledger, deviceName: deviceName)
            let coordinator = SyncCoordinator(
                engine: engine, publishDelay: publishDelay, makeClient: makeClient, resolveHost: resolveHost, relayProvider: relayProvider,
                report: { [weak self] update in
                    Task { @MainActor in self?.apply(update, token: token) }
                })
            self.coordinator = coordinator
            try await coordinator.start()
            guard current() else {
                await coordinator.stop()
                return
            }
            devices = await coordinator.deviceInfos()
            startDebugHooks(ledger: ledger, coordinator: coordinator)
        } catch {
            guard current() else { return }
            status = .error(Self.message(for: error))
            lastError = status == .off ? nil : Self.message(for: error)
        }
    }

    /// Registers the agent when needed and re-registers it after an app update (launchd pins the agent's checksum).
    /// Returns false while waiting for the user's approval (a poll continues in the background and relaunches).
    private func ensureRegistered(token: Int) async throws -> Bool {
        var state = registrar.status()
        if state == .notFound {
            status = .error("The sync helper is missing from this build of IMM.")
            return false
        }
        let registeredBuild = defaults.string(forKey: "syncAgentRegisteredBuild")
        if state == .enabled, registeredBuild != bundleVersion {
            try? await registrar.unregister()
            state = registrar.status()
        }
        if state == .notRegistered {
            do { try registrar.register() } catch {
                if registrar.status() != .requiresApproval { throw error }
            }
            state = registrar.status()
        }
        switch state {
        case .enabled:
            defaults.set(bundleVersion, forKey: "syncAgentRegisteredBuild")
            return true
        case .requiresApproval:
            status = .needsApproval
            defaults.set(bundleVersion, forKey: "syncAgentRegisteredBuild")
            registrar.openApprovalSettings()
            Task { [weak self] in
                while let self, token == self.generation, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    if self.registrar.status() == .enabled {
                        if token == self.generation { self.launch() }
                        return
                    }
                }
            }
            return false
        case .notRegistered, .notFound:
            throw SyncError.agentUnavailable("The sync helper could not be registered.")
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case SyncError.agentUnavailable(let text): return text
        case SyncError.noTailscale: return "Tailscale is not running."
        default: return "\(error)"
        }
    }

    // MARK: Updates from the coordinator

    private func apply(_ update: SyncUpdate, token: Int) {
        guard token == generation else { return }
        switch update {
        case .agent(let agent):
            if agent.listening, let host = agent.host {
                status = .listening(host: resolvedHosts[host] ?? host)
                if resolvedHosts[host] == nil {
                    let resolve = resolveHost
                    Task { [weak self] in
                        let name = await resolve(host)
                        await MainActor.run {
                            guard let self, token == self.generation else { return }
                            self.resolvedHosts[host] = name
                            if case .listening = self.status { self.status = .listening(host: name) }
                        }
                    }
                }
                printPairingCodeIfRequested()
            } else if let problem = agent.listenerError {
                status = .error(problem)
            } else {
                status = .noTailscale
            }
            refreshDevices()
        case .pairing(let phase):
            pairing = phase
            if case .confirming(_, let code) = phase, debugOptions.autoConfirm, autoConfirmed != code {
                autoConfirmed = code
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    try? await self?.confirmPairing()
                }
            }
        case .devices:
            refreshDevices()
        case .remoteApplied(let ops):
            lastRemoteChange = Date()
            refreshDevices()
            if debugOptions.dumpOnChange {
                for op in ops { SyncDebugLog.write("remote-op \(op.table) \(op.rowID) \(op.column ?? "-") \(Self.describe(op.value ?? .null)) device=\(String(op.device, radix: 16)) seq=\(op.seq)") }
            }
        case .relay(let status):
            relayStatus = status
            SyncDebugLog.write("relay \(status)")
        case .failure(let text):
            lastError = text
            SyncDebugLog.write("error \(text)")
        }
    }

    private static func describe(_ value: SyncValue) -> String {
        switch value {
        case .null: return "null"
        case .integer(let v): return "\(v)"
        case .real(let v): return "\(v)"
        case .text(let v): return "\"\(v)\""
        case .blob(let v): return "blob(\(v.count))"
        }
    }

    private func refreshDevices() {
        guard let coordinator else { return }
        let token = generation
        Task { [weak self] in
            let infos = await coordinator.deviceInfos()
            await MainActor.run {
                guard let self, token == self.generation else { return }
                self.devices = infos
            }
        }
    }

    // MARK: Pairing and removal

    /// Starts an offer: QR payload, code and expiry (120 s). The agent accepts one pairing handshake with it.
    public func beginPairing() async throws -> PairingOffer {
        guard let coordinator else { throw isEnabled ? SyncError.noTailscale : SyncError.agentUnavailable("Sync is off.") }
        return try await coordinator.beginPairing()
    }

    /// The user confirmed that both screens show the same code. `code` (what the user typed, if the UI asks for it) must match.
    public func confirmPairing(_ code: String? = nil) async throws {
        guard let coordinator else { throw SyncError.pairingNotActive }
        try await coordinator.confirmPairing(code)
        refreshDevices()
    }

    public func rejectPairing() async {
        await coordinator?.rejectPairing()
    }

    /// Cancels an offer nobody used yet.
    public func cancelPairing() async {
        await coordinator?.rejectPairing()
    }

    /// Removes a device: new group key, allow-list without it, remaining devices told.
    public func remove(device id: DeviceNodeID) async throws {
        guard let coordinator else { throw SyncError.agentUnavailable("Sync is off.") }
        try await coordinator.remove(node: id)
        refreshDevices()
    }

    /// Publishes what the devices lack and greets connected ones (their cursors correct any drift); fetches from the relay.
    public func syncNow() async {
        await coordinator?.publishNow()
    }

    // MARK: Debug hooks

    private func startDebugHooks(ledger: LedgerStore, coordinator: SyncCoordinator) {
        let options = debugOptions
        if options.debugEdit {
            let syncOff: @Sendable () async -> Void = { [weak self] in await self?.setEnabled(false) }
            debugTasks.append(Task {
                await SyncDebugCommands.watch(ledger: ledger, log: { SyncDebugLog.write($0) }, syncOff: syncOff)
            })
        }
        if options.printPairingCode { printPairingCodeIfRequested() }
    }

    private func printPairingCodeIfRequested() {
        guard debugOptions.printPairingCode, !printedPairing, case .listening = status, let coordinator else { return }
        printedPairing = true
        Task { [weak self] in
            do {
                let offer = try await coordinator.beginPairing()
                SyncDebugLog.writePairing(offer)
            } catch {
                await MainActor.run { self?.printedPairing = false }
                SyncDebugLog.write("pairing offer failed: \(error)")
            }
        }
    }
}
