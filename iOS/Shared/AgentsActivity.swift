import ActivityKit
import AgentTermProtocol
import Foundation

/// The Live Activity of the agents on a Mac (#24, #168): the host's state
/// now, counted by kind (`AgentsStatus`), the same struct the host pushes
/// for it while the app is asleep. Only the sessions' names, never what the
/// agents said: it is on the lock screen.
struct AgentsActivityAttributes: ActivityAttributes {
    typealias ContentState = AgentsStatus

    /// The Mac the agents run on.
    var mac: String
}
