import Foundation

/// What the apps ask before closing a tab of the Mac's strip and all it
/// holds, and before ending an agent with the shells and pages it opened
/// (#145): in the same words on the Mac and on the iPhone (principle 9).
public enum CloseWords {
    /// The question before a session is ended.
    public static func endQuestion(_ name: String) -> String { "End \(name)?" }

    /// What ending it does: an agent's shells and pages go with it.
    public static func endMessage(shells: Int, pages: Int) -> String {
        let stopped = "The program running in it is stopped."
        var parts: [String] = []
        if shells > 0 { parts.append(count(shells, "shell", "shells")) }
        if pages > 0 { parts.append(count(pages, "page", "pages")) }
        guard !parts.isEmpty else { return stopped }
        return "\(stopped) Its \(parts.joined(separator: " and ")) \(shells + pages == 1 ? "is" : "are") closed with it."
    }

    public static let endButton = "End Session"

    /// The question before a tab of the user's own is closed: "End 3 shells?".
    public static func groupQuestion(_ kind: HolderKind, count: Int) -> String {
        switch kind {
        case .shells: return "End \(Self.count(count, "shell", "shells"))?"
        case .browser: return "Close \(Self.count(count, "page", "pages"))?"
        case .diffs: return "Close \(Self.count(count, "diff", "diffs"))?"
        case .files: return "Close \(Self.count(count, "file", "files"))?"
        }
    }

    /// What closing it does.
    public static func groupMessage(_ kind: HolderKind) -> String {
        switch kind {
        case .shells: return "Every shell of the Shells tab is ended, and what runs in them is stopped."
        case .browser: return "Every page of the Browser tab is closed."
        case .diffs: return "Every diff of the Diffs tab is closed."
        case .files: return "Every file of the Files tab is closed. A file with unsaved changes is asked about first."
        }
    }

    /// The button that does it: "End 3 Shells".
    public static func groupButton(_ kind: HolderKind, count: Int) -> String {
        switch kind {
        case .shells: return count == 1 ? "End Shell" : "End \(count) Shells"
        case .browser: return count == 1 ? "Close Page" : "Close \(count) Pages"
        case .diffs: return count == 1 ? "Close Diff" : "Close \(count) Diffs"
        case .files: return count == 1 ? "Close File" : "Close \(count) Files"
        }
    }

    /// The tab's menu item and its ×'s help: what closing it does. Not
    /// "Close All Files", which is the pane's, files and diffs together.
    public static func groupAction(_ kind: HolderKind) -> String {
        switch kind {
        case .shells: return "End Shells"
        case .browser: return "Close Browser"
        case .diffs: return "Close Diffs"
        case .files: return "Close Files"
        }
    }

    private static func count(_ number: Int, _ one: String, _ many: String) -> String {
        number == 1 ? "1 \(one)" : "\(number) \(many)"
    }
}
