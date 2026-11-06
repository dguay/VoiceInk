import Darwin
import Foundation

struct PhoneDictationAddress: Hashable, Identifiable {
    enum Kind: String {
        case lan
        case tailscale
    }

    let kind: Kind
    let address: String
    let interface: String

    var id: String { "\(interface)-\(address)" }
}

/// The IPv4 addresses a phone can use to reach this Mac.
enum PhoneDictationAddresses {
    /// Tailscale assigns addresses from the CGNAT range 100.64.0.0/10.
    static func kind(forIPv4 address: String) -> PhoneDictationAddress.Kind? {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        switch (octets[0], octets[1]) {
        case (127, _), (0, _):
            return nil
        case (169, 254):
            // Link-local addresses are not routable from a phone.
            return nil
        case (100, 64...127):
            return .tailscale
        default:
            return octets[0] >= 224 ? nil : .lan
        }
    }

    /// Interfaces that are up, sorted with LAN addresses first.
    static func current() -> [PhoneDictationAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var results: [PhoneDictationAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                let socketAddress = entry.ifa_addr, socketAddress.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    socketAddress, socklen_t(socketAddress.pointee.sa_len), &host, socklen_t(host.count),
                    nil, 0, NI_NUMERICHOST) == 0
            else { continue }

            let address = String(cString: host)
            let interface = String(cString: entry.ifa_name)
            guard let kind = kind(forIPv4: address) else { continue }
            let candidate = PhoneDictationAddress(kind: kind, address: address, interface: interface)
            if !results.contains(where: { $0.address == address }) {
                results.append(candidate)
            }
        }
        return results.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .lan }
            return lhs.interface < rhs.interface
        }
    }
}
