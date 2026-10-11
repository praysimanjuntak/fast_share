import Darwin
import SystemConfiguration

/// An IPv4 address of this Mac that a phone on the same network can reach.
public struct LocalAddress: Hashable, Sendable, Identifiable {
    /// Declaration order is preference order when picking the default address.
    public enum Kind: Int, Sendable, Comparable {
        case wifi
        case ethernet
        case other

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let interfaceName: String
    public let ip: String
    /// Name shown in System Settings, e.g. "Wi-Fi" or "iPhone USB".
    public let displayName: String
    public let kind: Kind

    public var id: String { "\(interfaceName)/\(ip)" }

    public init(interfaceName: String, ip: String, displayName: String, kind: Kind) {
        self.interfaceName = interfaceName
        self.ip = ip
        self.displayName = displayName
        self.kind = kind
    }
}

public enum LocalAddresses {
    /// Addresses on physical interfaces (Wi‑Fi, Ethernet, USB tethering) and bridges, best first.
    /// VPN tunnels, AirDrop links and self-assigned 169.254.x.x addresses are skipped: phones can't reach them.
    public static func current() -> [LocalAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        let interfaces = interfaceInfo()
        var addresses: [LocalAddress] = []
        var cursor = head
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING), flags & IFF_LOOPBACK == 0,
                  let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge"),
                  let ip = numericHost(socketAddress), !ip.hasPrefix("169.254.")
            else { continue }
            let info = interfaces[name]
            addresses.append(LocalAddress(
                interfaceName: name,
                ip: ip,
                displayName: info?.displayName ?? name,
                kind: info?.kind ?? .other
            ))
        }
        return addresses.sorted { ($0.kind, $0.interfaceName) < ($1.kind, $1.interfaceName) }
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard result == 0 else { return nil }
        return host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func interfaceInfo() -> [String: (displayName: String, kind: LocalAddress.Kind)] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var info: [String: (displayName: String, kind: LocalAddress.Kind)] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(interface)
            let kind: LocalAddress.Kind
            if type == kSCNetworkInterfaceTypeIEEE80211 {
                kind = .wifi
            } else if type == kSCNetworkInterfaceTypeEthernet {
                kind = .ethernet
            } else {
                kind = .other
            }
            let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? bsdName
            info[bsdName] = (displayName, kind)
        }
        return info
    }
}
