import Foundation

/// Names shared by the app, the agent bundle and the build files (`Agent/`, `project.yml`). A fork with another team or
/// bundle id changes them here, in `Agent/*.entitlements`, `Agent/dev.gasi.imm.sync-agent.plist` and `project.yml`.
public enum AgentConstants {
    public static let teamIdentifier = "HHK7S6D2TR"
    /// Team-prefixed app group: needs no provisioning profile and shows no container-access prompt.
    public static let appGroup = "HHK7S6D2TR.dev.gasi.imm"
    /// Mach service of the agent; prefixed with the app group so a sandboxed app may look it up without an exception.
    public static let machServiceName = "HHK7S6D2TR.dev.gasi.imm.sync-agent"
    public static let appBundleIdentifier = "dev.gasi.imm"
    public static let agentBundleIdentifier = "dev.gasi.imm.sync-agent"
    /// Name of the LaunchAgent plist under `IMM.app/Contents/Library/LaunchAgents/` (for `SMAppService.agent(plistName:)`).
    public static let launchAgentPlistName = "dev.gasi.imm.sync-agent.plist"
    /// Bundle-relative path of the agent executable (`BundleProgram` in the plist).
    public static let agentExecutablePath = "Contents/Library/LoginItems/IMM Sync Agent.app/Contents/MacOS/IMM Sync Agent"
    /// TCP port of the tailnet listener.
    public static let defaultPort: UInt16 = 47_380
    /// Bumped when the XPC interface changes incompatibly; the app compares it with `AgentStatus.protocolVersion`.
    public static let xpcProtocolVersion = 1
    /// UserDefaults key (standard defaults, then the app-group suite) that overrides the port in DEBUG agent builds.
    public static let debugPortDefaultsKey = "IMMSyncPort"
}

public enum AgentError: Error, Equatable, Sendable {
    case groupContainerUnavailable
    case corruptIdentity
    case ownerKeyMissing
    case notAttached
    case io(String)
}
