import Foundation

/// The tabs of the Mac's strip that hold the user's own things, one of each
/// a folder (#127): the shells, the pages, the diffs and the files the user
/// opened. An agent's own shells and pages are in its tab instead. What
/// both apps call them is written here, once.
public enum HolderKind: String, CaseIterable, Sendable {
    case shells, browser, diffs, files

    public var title: String {
        switch self {
        case .shells: return "Shells"
        case .browser: return "Browser"
        case .diffs: return "Diffs"
        case .files: return "Files"
        }
    }

    /// The symbol shown beside its name.
    public var symbol: String {
        switch self {
        case .shells: return "terminal"
        case .browser: return "globe"
        case .diffs: return "plus.forwardslash.minus"
        case .files: return "doc.on.doc"
        }
    }

    /// What it says to assistive tools: its name, and how many it holds
    /// when there are several ("Browser, 3 pages").
    public func spoken(_ count: Int) -> String {
        guard count > 1 else { return title }
        switch self {
        case .shells: return "\(title), \(count) shells"
        case .browser: return "\(title), \(count) pages"
        case .diffs: return "\(title), \(count) diffs"
        case .files: return "\(title), \(count) files"
        }
    }

    /// Its name with how many it holds, as its tab shows it: "Shells (2)".
    public func label(_ count: Int) -> String { count > 1 ? "\(title) (\(count))" : title }
}

/// What an agent itself is called beside its own shells and pages: the
/// first item of its row on the Mac, a part of its screen on the iPhone.
/// Never its name, which its tab says already (#146).
public enum AgentPartWords {
    public static let agent = "Agent"
}
