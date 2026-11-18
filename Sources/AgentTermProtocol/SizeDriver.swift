import Foundation

/// The device whose size a session has, as the host tells the others
/// (#120): its name, and whether it is the Mac's own app.
public struct SizeDriver: Codable, Equatable, Sendable {
    public var name: String
    public var isMac: Bool

    public init(name: String, isMac: Bool) {
        self.name = name
        self.isMac = isMac
    }

    /// What the banner over a terminal says, on the Mac and on the iPhone
    /// alike, while another device decides its size.
    public static func inUse(by driver: SizeDriver?, size: TermSize) -> String {
        "In use on \(driver?.name ?? "another device") · \(size.cols)×\(size.rows)"
    }

    /// The picture beside it: a Mac's, or a phone's and a tablet's.
    public static func symbol(for driver: SizeDriver?) -> String { driver?.isMac == true ? "macbook" : "ipad.and.iphone" }
}
