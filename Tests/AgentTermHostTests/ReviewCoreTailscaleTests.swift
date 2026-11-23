import Darwin
import XCTest

@testable import AgentTermHost

/// #268 (review of 2026-11-22): the host takes any address in
/// 100.64.0.0/10 on any interface for this Mac's Tailscale address, and
/// listens on it.
final class ReviewCoreTailscaleTests: XCTestCase {
    /// The interfaces that are up with an address in 100.64.0.0/10: name and address.
    private func inRange() -> [(name: String, address: String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var found: [(String, String)] = []
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET), entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if raw & 0xFFC0_0000 == 0x6440_0000 {
                found.append((String(cString: entry.pointee.ifa_name), "\(raw >> 24).\((raw >> 16) & 0xff).\((raw >> 8) & 0xff).\(raw & 0xff)"))
            }
        }
        return found
    }

    /// With no Tailscale on the Mac and nothing known of it, an address in
    /// the carrier-grade range (a carrier's, another VPN's) is not a
    /// Tailscale connection, and no pairing code is offered for it.
    func testAnAddressInTheRangeIsNotTailscaleWhereTailscaleIsNotInstalled() {
        let status = Tailscale.status(installed: false, backendState: nil, address: "100.96.0.5", dnsName: nil)
        XCTAssertEqual(status, .notInstalled, "an address alone, on a Mac without Tailscale, was taken for a working Tailscale connection")
    }

    /// On this Mac: the address the host would listen on is the one
    /// Tailscale itself says is this Mac's. Skipped where Tailscale's
    /// command is not there or does not answer. Addresses are not printed:
    /// only the interfaces' names and whether they agree.
    func testTheAddressTheHostListensOnIsTheOneTailscaleSays() throws {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let cli = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { throw XCTSkip("Tailscale's command is not on this Mac") }
        guard let result = Subprocess.run(cli, ["ip", "-4"], timeout: 4), result.status == 0 else { throw XCTSkip("Tailscale's command did not answer") }
        let own = String(decoding: result.output, as: UTF8.self).split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        try XCTSkipIf(own.isEmpty, "Tailscale gave no address: not connected")
        let found = inRange()
        let taken = Tailscale.ipv4Address(own: Tailscale.ownAddresses())
        let names = found.map(\.name).joined(separator: ", ")
        let takenFrom = found.first { $0.address == taken }?.name ?? "none"
        let tailscales = found.first { $0.address == own }?.name ?? "none"
        XCTAssertTrue(taken == own, "interfaces up in 100.64.0.0/10: \(names); the host takes the address of \(takenFrom), Tailscale's own is on \(tailscales)")
    }

    /// #268: which address is taken, whatever this Mac has.
    func testOnlyTailscalesOwnAddressIsTaken() {
        let warp = (interface: "utun5", address: "100.96.0.5"), tailscale = (interface: "utun11", address: "100.102.112.76")
        let carrier = (interface: "en0", address: "100.70.1.2")
        XCTAssertEqual(Tailscale.address(among: [warp, tailscale], own: ["100.102.112.76"], installed: true), "100.102.112.76", "another VPN's tunnel, listed first")
        XCTAssertNil(Tailscale.address(among: [warp], own: [], installed: true), "Tailscale asked, and the address is not its own")
        XCTAssertNil(Tailscale.address(among: [carrier], own: nil, installed: true), "a carrier's address on an interface that is no tunnel")
        XCTAssertNil(Tailscale.address(among: [tailscale], own: nil, installed: false), "a Mac without Tailscale")
        XCTAssertEqual(Tailscale.address(among: [carrier, tailscale], own: nil, installed: true), "100.102.112.76", "Tailscale not asked: the tunnel")
    }
}
