#if os(macOS)
import CoreServices
import Darwin
import Foundation

/// Whether a phone could reach this Mac over Tailscale right now.
public enum TailscaleStatus: Equatable, Sendable {
    /// Tailscale is not on this Mac.
    case notInstalled
    /// Installed, but nobody is signed in.
    case needsLogin
    /// Installed and signed in, but switched off or still starting.
    case notConnected
    /// Connected. `host` is the name or address a phone should use.
    case ready(host: String)
}

/// Reads this Mac's Tailscale identity without depending on Tailscale itself.
public enum Tailscale {
    private static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    private static var cli: String? {
        cliCandidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// True when the Tailscale app or command line tool is on this Mac.
    public static var isInstalled: Bool {
        if cli != nil { return true }
        // The app can live outside /Applications; ask the system by identifier
        // (App Store build, then the standalone build).
        return ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"].contains { identifier in
            LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil) != nil
        }
    }

    /// Checks installation and connection. Runs the Tailscale CLI when there
    /// is one, so call it off the main thread.
    public static func status() -> TailscaleStatus {
        var backendState: String?
        var dnsName: String?
        var own: Set<String>?
        if let json = askedStatus() {
            backendState = json["BackendState"] as? String
            dnsName = (json["Self"] as? [String: Any])?["DNSName"] as? String
            own = Set(json["TailscaleIPs"] as? [String] ?? [])
        }
        let installed = isInstalled
        return status(installed: installed, backendState: backendState, address: address(among: addressesInRange(), own: own, installed: installed), dnsName: dnsName)
    }

    /// What `tailscale status --json` says (Tailscale 1.104.7 has
    /// `BackendState`, `Self.DNSName` and `TailscaleIPs`); nil when its
    /// command is not there or does not answer.
    private static func askedStatus() -> [String: Any]? {
        guard let cli, let result = Subprocess.run(cli, ["status", "--json"], timeout: 4), result.status == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: result.output) as? [String: Any]
    }

    /// The addresses Tailscale itself says are this Mac's; nil when it
    /// could not be asked. Runs its command: off the host's queue.
    public static func ownAddresses() -> Set<String>? {
        askedStatus().map { Set($0["TailscaleIPs"] as? [String] ?? []) }
    }

    /// The decision behind `status()`, separated from the system calls.
    static func status(installed: Bool, backendState: String?, address: String?, dnsName: String?) -> TailscaleStatus {
        // No Tailscale on the Mac: an address in its range is someone
        // else's, a carrier's or another VPN's (#268).
        guard installed else { return .notInstalled }
        // An address Tailscale's own, or on a tunnel of a Mac with Tailscale,
        // is proof enough of a working connection, even where the CLI
        // cannot be asked.
        if let address, backendState == nil || backendState == "Running" {
            let name = dnsName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            return .ready(host: name?.isEmpty == false ? name! : address)
        }
        guard installed else { return .notInstalled }
        return backendState == "NeedsLogin" ? .needsLogin : .notConnected
    }

    /// The Mac's Tailscale address, if it is connected: one in the range
    /// 100.64.0.0/10 that Tailscale says is its own (`own`, from
    /// `ownAddresses()`), or when Tailscale cannot be asked, the first on a
    /// tunnel (`utun`) of a Mac that has Tailscale (#268).
    public static func ipv4Address(own: Set<String>? = nil) -> String? {
        address(among: addressesInRange(), own: own, installed: isInstalled)
    }

    /// The decision behind `ipv4Address`: never an address of an interface
    /// that is not a tunnel (a carrier's), nor on a Mac without Tailscale,
    /// nor, once Tailscale was asked, one it does not say is its own
    /// (another VPN's tunnel, Cloudflare WARP's).
    static func address(among found: [(interface: String, address: String)], own: Set<String>?, installed: Bool) -> String? {
        if let own { return found.first { own.contains($0.address) }?.address }
        guard installed else { return nil }
        return found.first { $0.interface.hasPrefix("utun") }?.address
    }

    /// The interfaces that are up with an IPv4 address in 100.64.0.0/10.
    static func addressesInRange() -> [(interface: String, address: String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var found: [(interface: String, address: String)] = []
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                entry.pointee.ifa_flags & UInt32(IFF_UP) != 0
            else { continue }
            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if raw & 0xFFC0_0000 == 0x6440_0000 {
                found.append((String(cString: entry.pointee.ifa_name), "\(raw >> 24).\((raw >> 16) & 0xff).\((raw >> 8) & 0xff).\(raw & 0xff)"))
            }
        }
        return found
    }

    /// The Mac's MagicDNS name, e.g. "macbook.tail1234.ts.net". Needs the
    /// Tailscale CLI, which ships inside the app.
    public static func dnsName() -> String? {
        guard let cli, let result = Subprocess.run(cli, ["status", "--json"], timeout: 4), result.status == 0,
            let json = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
            let me = json["Self"] as? [String: Any],
            let name = me["DNSName"] as? String
        else { return nil }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
