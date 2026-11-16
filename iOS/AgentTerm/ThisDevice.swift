import UIKit

/// What the app calls the device it runs on, in what it says: "this iPhone"
/// on an iPhone, "this iPad" on an iPad (#88).
enum ThisDevice {
    static let name = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
}
