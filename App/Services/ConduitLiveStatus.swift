import ActivityKit
import Foundation

/// Status only. A Live Activity does not grant background GPU execution.
@MainActor final class ConduitLiveStatus {
    static let shared = ConduitLiveStatus()
    static let enabledKey = "conduit.appearance.liveActivity"
    private var activity: Activity<ConduitActivityAttributes>?
    private var paused = false
    private var updateTask: Task<Void, Never>?

    func setWorking(_ working: Bool, foreground: Bool, status: String) {
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        guard enabled else { finish(); return }
        guard foreground else { if working { pause() }; return }
        guard working else { finish(); return }
        paused = false
        let state = ConduitActivityAttributes.ContentState(status: status, paused: false)
        if let activity {
            updateTask?.cancel()
            updateTask = Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(900))) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            // Reconcile a prior process that ended before it could dismiss its activity.
            for old in Activity<ConduitActivityAttributes>.activities {
                Task { await old.end(nil, dismissalPolicy: .immediate) }
            }
            activity = try? Activity.request(attributes: ConduitActivityAttributes(taskID: UUID()),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(900)), pushType: nil)
        }
    }

    func pause() {
        guard let activity, !paused else { return }
        paused = true
        updateTask?.cancel()
        updateTask = Task {
            await activity.update(ActivityContent(state: .init(status: "Paused — open Conduit to continue", paused: true),
                staleDate: Date().addingTimeInterval(900)))
        }
    }

    private func finish() {
        updateTask?.cancel()
        let activities = Activity<ConduitActivityAttributes>.activities
        activity = nil
        paused = false
        updateTask = Task {
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
