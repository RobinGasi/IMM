import Darwin
import Foundation
import IMMSyncCore
import ServiceManagement

public enum AgentRegistrationStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    /// The user must allow IMM in System Settings › General › Login Items (macOS asks once).
    case requiresApproval
    /// The bundle has no agent plist (swift run, unsigned build, tests).
    case notFound
}

/// Registers the LaunchAgent that runs `IMM Sync Agent.app` (`SMAppService.agent`). A protocol so tests need no launchd.
public protocol AgentRegistrar: Sendable {
    func status() -> AgentRegistrationStatus
    func register() throws
    func unregister() async throws
    func openApprovalSettings()
}

public struct SMAppServiceRegistrar: AgentRegistrar {
    public init() {}

    private var service: SMAppService { SMAppService.agent(plistName: AgentConstants.launchAgentPlistName) }

    public func status() -> AgentRegistrationStatus {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notFound
        }
    }

    public func register() throws { try service.register() }
    public func unregister() async throws { try await service.unregister() }
    public func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Reverse DNS of a tailnet address: Tailscale's resolver answers `*.ts.net` names for 100.x addresses.
public enum MagicDNS {
    /// The MagicDNS name of `address` (without the trailing dot), or `address` itself when it does not resolve within `timeout`.
    public static func name(for address: String, timeout: Duration = .seconds(2)) async -> String {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { lookup(address) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? address
        }
    }

    private static func lookup(_ address: String) -> String? {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &socketAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard status == 0 else { return nil }
        var name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name.hasSuffix(".") { name.removeLast() }
        return name.hasSuffix(".ts.net") ? name : nil
    }
}
