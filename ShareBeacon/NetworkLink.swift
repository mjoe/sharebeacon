import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// The kind of interface the route to a share's host leaves the Mac through.
enum NetworkLinkKind: String, Sendable {
    case wired
    case wifi
    case tunnel
    case other
}

/// The local interface macOS routes a share's traffic through.
struct NetworkLink: Equatable, Sendable {
    let interfaceName: String
    let kind: NetworkLinkKind
    /// Link speed reported by the interface, or 0 when it reports none.
    let bitsPerSecond: UInt64

    var label: String {
        switch kind {
        case .wired:
            guard let speed = Self.speedLabel(bitsPerSecond) else { return "Ethernet" }
            return "Ethernet \(speed)"
        case .wifi:
            guard let speed = Self.speedLabel(bitsPerSecond) else { return "Wi-Fi" }
            return "Wi-Fi \(speed)"
        case .tunnel:
            return "VPN"
        case .other:
            return interfaceName
        }
    }

    var symbolName: String {
        switch kind {
        case .wired: return "cable.connector"
        case .wifi: return "wifi"
        case .tunnel: return "lock.shield"
        case .other: return "network"
        }
    }

    /// The link speed in a few characters, such as 2.5G or 866M, for the menu.
    var shortSpeed: String? {
        guard bitsPerSecond > 0 else { return nil }
        let gigabits = Double(bitsPerSecond) / 1_000_000_000
        if gigabits >= 1 {
            return "\(Self.trimmed(gigabits))G"
        }
        return "\(bitsPerSecond / 1_000_000)M"
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    static func speedLabel(_ bitsPerSecond: UInt64) -> String? {
        guard bitsPerSecond > 0 else { return nil }
        let gigabits = Double(bitsPerSecond) / 1_000_000_000
        if gigabits >= 1 {
            return "\(trimmed(gigabits)) Gb/s"
        }
        return "\(bitsPerSecond / 1_000_000) Mb/s"
    }

    /// Classifies an interface from its BSD name and its System Configuration type.
    static func kind(interfaceName: String, systemType: String?) -> NetworkLinkKind {
        let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]
        if tunnelPrefixes.contains(where: interfaceName.hasPrefix) {
            return .tunnel
        }
        switch systemType {
        case "IEEE80211": return .wifi
        case "Ethernet": return .wired
        default: return .other
        }
    }
}

/// Which link a share is expected to use. A share that expects a wired link is
/// flagged when macOS routes it through anything else.
enum LinkExpectation: String, Codable, CaseIterable, Sendable {
    case any
    case wired

    /// An unknown link is never flagged, because nothing can be said about it.
    func isSatisfied(by link: NetworkLink?) -> Bool {
        guard self == .wired, let link else { return true }
        return link.kind == .wired
    }
}

protocol NetworkLinkResolving: Sendable {
    func link(toHost host: String) -> NetworkLink?
    func link(forInterface name: String) -> NetworkLink?
}

/// Asks the routing table which interface reaches a host.
///
/// Connecting a UDP socket sends nothing; it only makes the kernel pick a route
/// and a source address, which then names the interface SMB uses as well.
struct SystemNetworkLinkResolver: NetworkLinkResolving {
    func link(toHost host: String) -> NetworkLink? {
        guard let localAddress = Self.sourceAddress(toHost: host),
              let interface = Self.interface(owning: localAddress)
        else { return nil }
        return Self.link(interfaceName: interface.name, baudRate: interface.bitsPerSecond)
    }

    func link(forInterface name: String) -> NetworkLink? {
        guard let speed = Self.linkSpeeds()[name] else { return nil }
        return Self.link(interfaceName: name, baudRate: speed)
    }

    private static func link(interfaceName: String, baudRate: UInt64) -> NetworkLink {
        let kind = NetworkLink.kind(
            interfaceName: interfaceName,
            systemType: systemInterfaceTypes()[interfaceName]
        )
        // Wi-Fi reports no fixed baud rate, so the current transmit rate stands in.
        let bitsPerSecond = kind == .wifi ? wifiTransmitRate(interfaceName: interfaceName) : baudRate
        return NetworkLink(interfaceName: interfaceName, kind: kind, bitsPerSecond: bitsPerSecond)
    }

    private static func sourceAddress(toHost host: String) -> Data? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "445", &hints, &result) == 0, let result else { return nil }
        defer { freeaddrinfo(result) }

        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let current = cursor {
            cursor = current.pointee.ai_next
            let info = current.pointee
            guard let address = info.ai_addr else { continue }
            let descriptor = socket(info.ai_family, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard connect(descriptor, address, info.ai_addrlen) == 0 else { continue }

            var local = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let named = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else { continue }
            if let bytes = addressBytes(&local) {
                return bytes
            }
        }
        return nil
    }

    private static func addressBytes(_ storage: UnsafeMutablePointer<sockaddr_storage>) -> Data? {
        switch Int32(storage.pointee.ss_family) {
        case AF_INET:
            return storage.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Data($0) }
            }
        case AF_INET6:
            return storage.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Data($0) }
            }
        default:
            return nil
        }
    }

    private static func interface(owning address: Data) -> (name: String, bitsPerSecond: UInt64)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return nil }
        defer { freeifaddrs(list) }

        var owner: String?
        var speeds: [String: UInt64] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = list
        while let current = cursor {
            cursor = current.pointee.ifa_next
            guard let socketAddress = current.pointee.ifa_addr else { continue }
            let name = String(cString: current.pointee.ifa_name)
            let family = Int32(socketAddress.pointee.sa_family)
            if family == AF_LINK, let data = current.pointee.ifa_data {
                let linkData = data.assumingMemoryBound(to: if_data.self).pointee
                speeds[name] = UInt64(linkData.ifi_baudrate)
            } else if owner == nil, family == AF_INET || family == AF_INET6 {
                var storage = sockaddr_storage()
                memcpy(&storage, socketAddress, Int(socketAddress.pointee.sa_len))
                if addressBytes(&storage) == address {
                    owner = name
                }
            }
        }
        guard let owner else { return nil }
        return (owner, speeds[owner] ?? 0)
    }

    private static func linkSpeeds() -> [String: UInt64] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return [:] }
        defer { freeifaddrs(list) }
        var speeds: [String: UInt64] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = list
        while let current = cursor {
            cursor = current.pointee.ifa_next
            guard let address = current.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK,
                  let data = current.pointee.ifa_data
            else { continue }
            speeds[String(cString: current.pointee.ifa_name)] =
                UInt64(data.assumingMemoryBound(to: if_data.self).pointee.ifi_baudrate)
        }
        return speeds
    }

    private static func wifiTransmitRate(interfaceName: String) -> UInt64 {
        guard let megabits = CWWiFiClient.shared().interface(withName: interfaceName)?.transmitRate(),
              megabits > 0
        else { return 0 }
        return UInt64(megabits * 1_000_000)
    }

    private static func systemInterfaceTypes() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var types: [String: String] = [:]
        for interface in interfaces {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
            else { continue }
            types[name] = type
        }
        return types
    }
}
