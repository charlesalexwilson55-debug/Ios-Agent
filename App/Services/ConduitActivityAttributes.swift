import ActivityKit
import Foundation

/// Shared with the lightweight Live Activity extension; contains no chat text.
struct ConduitActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var paused: Bool
    }
    var taskID: UUID
}
