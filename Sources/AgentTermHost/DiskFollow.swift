import Foundation

/// When a file was last seen to change, and its size: an open file is read
/// again only when either is another (#304). Only a regular file has one: a
/// pipe or a device is never read to follow it, as reading may never end.
public struct DiskStamp: Equatable, Sendable {
    public let modified: Date
    public let size: Int

    public init?(of path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let modified = attributes[.modificationDate] as? Date,
            let size = attributes[.size] as? Int
        else { return nil }
        self.modified = modified
        self.size = size
    }
}

/// How the Mac app's open files follow the disk (#304): what is read, off
/// the main thread, and which of what was read is taken.
public enum DiskFollow {
    /// An open file without edits, and the text it was last saved or read as.
    public struct Looked: Equatable, Sendable {
        public let path: String
        public let saved: String
        public init(path: String, saved: String) {
            self.path = path
            self.saved = saved
        }
    }

    /// A file whose text on the disk is not the one it was opened with.
    public struct Found: Equatable, Sendable {
        public let path: String
        public let text: String
        /// What the document held when it was looked at.
        public let saved: String
    }

    /// Each file's stamp now, and the text of those that changed. Reads only
    /// a file whose stamp is another than the one known; slow, so called off
    /// the main thread.
    public static func look(at files: [Looked], known: [String: DiskStamp]) -> (stamps: [String: DiskStamp], changed: [Found]) {
        var stamps: [String: DiskStamp] = [:]
        var changed: [Found] = []
        for file in files {
            guard let stamp = DiskStamp(of: file.path) else { continue }
            stamps[file.path] = stamp
            guard stamp != known[file.path] else { continue }
            if case .text(let onDisk) = FileBrowser.read(file.path), !same(onDisk, file.saved) {
                changed.append(Found(path: file.path, text: onDisk, saved: file.saved))
            }
        }
        return (stamps, changed)
    }

    /// Whether what was read is shown: not when the document was closed
    /// (`now` nil), edited, or saved meanwhile.
    public static func takes(_ found: Found, now: (isDirty: Bool, saved: String)?) -> Bool {
        guard let now, !now.isDirty else { return false }
        return same(now.saved, found.saved)
    }

    /// Unit for unit, the lengths first (#104).
    private static func same(_ left: String, _ right: String) -> Bool {
        let one = left as NSString
        return one.length == (right as NSString).length && one.isEqual(to: right)
    }
}
