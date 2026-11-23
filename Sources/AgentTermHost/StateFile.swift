#if os(macOS)
import Foundation

/// A file the host keeps its state in (#273).
enum StateFile {
    /// Puts a file the host cannot read aside, under a name of its own next
    /// to it (`schedules.json.unreadable`, then with the time when that is
    /// taken), so that the host, which starts without what it held, never
    /// writes over it. Nil when it could not be moved.
    static func setAside(_ file: URL, now: Date = Date()) -> URL? {
        var aside = file.appendingPathExtension("unreadable")
        if FileManager.default.fileExists(atPath: aside.path) {
            aside = file.appendingPathExtension("unreadable-\(Int(now.timeIntervalSince1970))")
        }
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            return aside
        } catch {
            return nil
        }
    }

    /// Whether a file is there but holds what cannot be read: given what was
    /// read of it, and whether it decoded.
    static func isUnreadable(_ file: URL, decoded: Bool) -> Bool {
        !decoded && FileManager.default.fileExists(atPath: file.path)
    }
}
#endif
