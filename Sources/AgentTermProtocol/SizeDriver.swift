import Foundation

/// What a device that connects to a host is (#157): it says so itself when
/// it pairs and when it signs in, and the others show it by its own icon.
public enum DeviceKind: String, Codable, Equatable, Sendable {
    case mac, iphone, ipad

    /// Its icon beside what it does to a session or in the list of paired
    /// devices: none for a Mac (the owner's decision, 2026-11-18), the
    /// device's own for an iPhone or an iPad.
    public var symbol: String? {
        switch self {
        case .mac: return nil
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        }
    }
}

/// The device whose size a session has, as the host tells the others
/// (#120): its name, and what it is (#157), nil for one that has not said.
public struct SizeDriver: Codable, Equatable, Sendable {
    public var name: String
    public var kind: DeviceKind?

    public init(name: String, kind: DeviceKind?) {
        self.name = name
        self.kind = kind
    }

    /// What the banner over a terminal says, on the Mac and on the iPhone
    /// alike, while another device decides its size.
    public static func inUse(by driver: SizeDriver?, size: TermSize) -> String {
        "In use on \(driver?.name ?? "another device") · \(size.cols)×\(size.rows)"
    }

    /// The icon beside it: the device's own, none for a Mac or a device not
    /// known (#157).
    public static func symbol(for driver: SizeDriver?) -> String? { driver?.kind?.symbol }
}
