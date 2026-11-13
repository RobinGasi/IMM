import Foundation
import IMMSyncCore
import os

// IMM Sync Agent: a thin shell around `AgentServer` (IMMSyncCore). It owns the tailnet listener and the blind mailbox and
// talks to IMM over XPC. Started by launchd from `Contents/Library/LaunchAgents/dev.gasi.imm.sync-agent.plist`; logs go
// through os.Logger only (a sandboxed agent plist must not carry Standard*Path keys).

let log = Logger(subsystem: "dev.gasi.imm.sync-agent", category: "agent")
let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

let storage: AgentStorage
do {
    storage = try AgentStorage.appGroup()
} catch {
    log.fault("app group container unavailable: \(String(describing: error), privacy: .public)")
    exit(EX_CONFIG)
}

let server: AgentServer
do {
    server = try AgentServer(configuration: AgentConfiguration(
        storage: storage, binding: .tailnet(port: AgentConfiguration.resolvedPort()), build: build,
        log: { log.notice("\($0, privacy: .public)") }))
} catch {
    log.fault("cannot start the agent: \(String(describing: error), privacy: .public)")
    exit(EX_CONFIG)
}

// Unsigned (ad-hoc) debug builds cannot satisfy a team requirement: the requirement relaxes to the bundle identifier.
let requirement = AgentXPCRequirements.forAgentToTrustApp()
if requirement.relaxed { log.notice("XPC peer check relaxed to the bundle identifier (unsigned build)") }
let xpc = AgentXPCService(server: server, requirement: requirement.text)
xpc.resume()

Task {
    do {
        try await server.start()
        log.notice("agent \(build, privacy: .public) started")
    } catch {
        log.fault("listener start failed: \(String(describing: error), privacy: .public)")
        exit(EX_UNAVAILABLE)
    }
}

dispatchMain()
