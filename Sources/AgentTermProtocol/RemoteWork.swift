import Foundation

/// What is asked of a folder's remotes, and of git there, one thing at a
/// time (#116), on the Mac and on the iPhone alike.
///
/// What the user asks for holds the folder until it is over: `busy` says
/// with what, and the buttons wait. The fetch the app makes by itself
/// holds nothing. What is asked for while it is under way is kept, and
/// handed back to be begun when that fetch is over, so that the two are
/// never at the remotes together and nothing asked for is thrown away.
public struct RemoteWork<Work> {
    /// What the user asked for in each folder, while it is under way:
    /// "push", "pull", "fetch" and the rest.
    public private(set) var busy: [String: String] = [:]
    /// The folders whose remotes the app is asking by itself.
    private var quietly: Set<String> = []
    /// What the user asked for in a folder while that was under way.
    private var kept: [String: Work] = [:]

    public init() {}

    /// What comes of asking for something.
    public enum Answer: Equatable, Sendable {
        /// Something the user asked for is under way in the folder:
        /// nothing is begun beside it.
        case refused
        /// It is to be begun now.
        case begin
        /// The app is asking the folder's remotes by itself: it is kept,
        /// and handed back by `quietFetchEnded`.
        case kept
    }

    /// The user asks for `what` in a folder, which is busy with it from
    /// then on unless it is refused. `work` is what begins it.
    public mutating func ask(_ what: String, in folder: String, keeping work: Work) -> Answer {
        guard busy[folder] == nil else { return .refused }
        busy[folder] = what
        guard quietly.contains(folder) else { return .begin }
        kept[folder] = work
        return .kept
    }

    /// The app is about to ask a folder's remotes by itself. False when it
    /// is not to: it does already, or the user's own work is under way.
    public mutating func beginQuietFetch(in folder: String) -> Bool {
        guard busy[folder] == nil, !quietly.contains(folder) else { return false }
        quietly.insert(folder)
        return true
    }

    /// Whether the app is asking a folder's remotes by itself.
    public func isFetchingQuietly(in folder: String) -> Bool { quietly.contains(folder) }

    /// The app's own fetch of a folder is over: what the user asked for
    /// meanwhile, to be begun now.
    public mutating func quietFetchEnded(in folder: String) -> Work? {
        quietly.remove(folder)
        return kept.removeValue(forKey: folder)
    }

    /// What the user asked for in a folder is over. Says what it was.
    @discardableResult
    public mutating func ended(in folder: String) -> String? {
        kept[folder] = nil
        return busy.removeValue(forKey: folder)
    }

    /// The connection is gone, or is another: nothing is under way any
    /// more, and nothing that was kept is begun.
    public mutating func forgetAll() {
        busy = [:]
        quietly = []
        kept = [:]
    }
}
