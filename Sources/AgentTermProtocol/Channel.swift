import Foundation

/// Which build of AgentTerm this is.
///
/// A released build (the one from the GitHub release or TestFlight) and a
/// build made on a developer's own machine live side by side: each has its
/// own name, bundle identifier, data folder, port and pairing link scheme,
/// so trying a change never touches the installed app's sessions or
/// paired devices.
///
/// The channel is read from the bundle the code runs in. Only a bundle with
/// the released identifier is the release; everything else, a bare
/// `swift run` and the test runner included, is a development build.
public enum AppChannel: String, Sendable {
    case release
    case dev

    public static let releaseBundleIdentifier = "com.manhpham.agentterm"

    public static let current: AppChannel = Bundle.main.bundleIdentifier == releaseBundleIdentifier ? .release : .dev

    public var bundleIdentifier: String { self == .release ? Self.releaseBundleIdentifier : Self.releaseBundleIdentifier + ".dev" }

    /// "AgentTerm", or "AgentTerm Dev". Also the name of the data folder.
    public var appName: String { self == .release ? "AgentTerm" : "AgentTerm Dev" }

    /// The port the host listens on unless told otherwise.
    public var defaultPort: UInt16 { self == .release ? 7717 : 7718 }

    /// Scheme of the pairing link this build shows and opens.
    public var linkScheme: String { self == .release ? "agentterm" : "agentterm-dev" }

    public static let linkSchemes: Set<String> = [AppChannel.release.linkScheme, AppChannel.dev.linkScheme]

    /// The name this build's MCP server has in the agents' configuration
    /// (#57). Each build has its own, so that both can be installed and
    /// neither replaces the other's.
    public var mcpServerName: String { self == .release ? "agentterm" : "agentterm-dev" }

    /// The variable that names the file a session's hooks write in (#129):
    /// each build's own, so that the other build's hooks, which an agent
    /// may have too, leave this build's sessions alone (principle 7).
    public var eventsVariable: String { self == .release ? "AGENTTERM_EVENTS" : "AGENTTERM_DEV_EVENTS" }

    /// The variable that names the file Claude Code's status line writes
    /// what it is given in (#129), each build's own.
    public var usageVariable: String { self == .release ? "AGENTTERM_USAGE" : "AGENTTERM_DEV_USAGE" }
}

/// The version of the app that is running, as its bundle states it. Every
/// build takes it from the `VERSION` file at the root of the repository.
public enum AppVersion {
    /// "0.2.0", or "dev" for a program run outside an app bundle.
    public static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    /// "AgentTerm 0.2.0".
    public static var label: String { "\(AppChannel.current.appName) \(current)" }

    /// What the host this app comes with is built from, as
    /// `scripts/bundle-mac.sh` writes it (#121): the host, which runs from
    /// inside the bundle, reads the same. Nil outside an app bundle.
    public static var hostRevision: String? {
        Bundle.main.object(forInfoDictionaryKey: "AgentTermHostRevision") as? String
    }

    /// How the release a host says it is from compares with this app's
    /// (#121): a host left running when the app was updated is older, even
    /// when both speak the same protocol. `.same` when either is not known:
    /// a host before protocol 23 says none, and a build run outside an app
    /// bundle is "dev".
    public static func match(host: String?, own: String = current) -> ProtocolMatch {
        guard let host, host != "dev", own != "dev", host != own else { return .same }
        // "0.10.0" after "0.9.0"; a release after its betas ("0.10.0-beta.2").
        func parts(_ version: String) -> (main: String, suffix: String?) {
            let split = version.split(separator: "-", maxSplits: 1).map(String.init)
            return (split.first ?? version, split.count > 1 ? split[1] : nil)
        }
        let (hostMain, hostSuffix) = parts(host)
        let (ownMain, ownSuffix) = parts(own)
        let order: ComparisonResult
        switch hostMain.compare(ownMain, options: .numeric) {
        case .orderedSame:
            switch (hostSuffix, ownSuffix) {
            case (nil, _?): order = .orderedDescending
            case (_?, nil): order = .orderedAscending
            case (let host?, let own?): order = host.compare(own, options: .numeric)
            case (nil, nil): order = .orderedSame
            }
        case let other: order = other
        }
        switch order {
        case .orderedAscending: return .hostOlder
        case .orderedDescending: return .hostNewer
        case .orderedSame: return .same
        }
    }
}

/// Where AgentTerm lives on the web, for the apps to link to.
public enum ProjectLinks {
    /// The project's page: what it does, downloads, support.
    public static let page = URL(string: "https://manhdev.click/projects/agentterm")!
    /// The source code.
    public static let source = URL(string: "https://github.com/Bitfaring/AgentTerm")!
}
