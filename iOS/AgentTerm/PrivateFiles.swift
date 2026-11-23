import Foundation

/// Where the iPhone keeps what agents said and what the user wrote (#287):
/// the Inbox and the drafts, in files of the app's own, protected until the
/// device is first unlocked and left out of its backups, not among its
/// preferences, which go with every backup.
enum PrivateFiles {
    private static var folder: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("Private", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var excluded = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
        }
        return folder
    }

    private static func file(_ name: String) -> URL? { folder?.appendingPathComponent(name + ".json") }

    static func read(_ name: String) -> Data? { file(name).flatMap { try? Data(contentsOf: $0) } }

    static func write(_ data: Data, as name: String) {
        guard let file = file(name) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ name: String) {
        guard let file = file(name) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
