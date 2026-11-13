import Darwin
import Foundation
import Network

/// The interface that carries this Mac's tailnet address.
public struct TailnetInterface: Sendable, Equatable {
    /// `utunN`.
    public let name: String
    /// IPv4 address in 100.64.0.0/10.
    public let address: String
    /// Used for `NWParameters.requiredInterface`; excluded from equality (same name and address = same interface).
    public let interface: NWInterface?

    public init(name: String, address: String, interface: NWInterface?) {
        self.name = name
        self.address = address
        self.interface = interface
    }

    public static func == (lhs: TailnetInterface, rhs: TailnetInterface) -> Bool {
        lhs.name == rhs.name && lhs.address == rhs.address
    }
}

/// Source of tailnet-interface changes; the agent server uses `TailnetInterfaceMonitor`, tests a fake.
public protocol TailnetProviding: Sendable {
    /// Calls `onChange` with the current interface (nil = none) now and after every change.
    func start(onChange: @escaping @Sendable (TailnetInterface?) -> Void)
    func stop()
}

public enum TailnetAddress {
    /// `100.64.0.0/10` (carrier-grade NAT range Tailscale hands out).
    public static func isTailnetIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (parts[1] & 0xC0) == 0x40
    }

    /// IPv4 addresses of all local interfaces as `(interface name, address)`.
    public static func localIPv4Addresses() -> [(name: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [(String, String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            let hostBytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            result.append((String(cString: entry.pointee.ifa_name), String(decoding: hostBytes, as: UTF8.self)))
        }
        return result
    }

    /// First `utun*` interface in `available` that carries a tailnet address.
    static func select(addresses: [(name: String, address: String)], available: [NWInterface]) -> TailnetInterface? {
        for entry in addresses where entry.name.hasPrefix("utun") && isTailnetIPv4(entry.address) {
            if let interface = available.first(where: { $0.name == entry.name }) {
                return TailnetInterface(name: entry.name, address: entry.address, interface: interface)
            }
        }
        return nil
    }
}

/// `NWPathMonitor` → the `utun` interface with a 100.64.0.0/10 address. Reports only real changes.
public final class TailnetInterfaceMonitor: TailnetProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.gasi.imm.sync-agent.tailnet")
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var last: TailnetInterface?
    private var reported = false

    public init() {}

    public func start(onChange: @escaping @Sendable (TailnetInterface?) -> Void) {
        lock.lock()
        monitor?.cancel()
        let monitor = NWPathMonitor()
        self.monitor = monitor
        reported = false
        lock.unlock()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let found = TailnetAddress.select(addresses: TailnetAddress.localIPv4Addresses(), available: path.availableInterfaces)
            self.lock.lock()
            let changed = !self.reported || found != self.last
            self.reported = true
            self.last = found
            self.lock.unlock()
            if changed { onChange(found) }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        monitor?.cancel()
        monitor = nil
        lock.unlock()
    }
}
