import AppIntents
import Foundation

/// Exposes Conduit to Shortcuts and Siri.
///
/// This is the half of the Shortcuts story that people miss. `run_shortcut`
/// lets the model call *out* to Shortcuts; an App Intent lets Shortcuts and
/// Siri call *in*. Together they close the loop: a shortcut can hand Conduit a
/// task, and Conduit can hand work back to a shortcut.
///
/// Note what this deliberately does not attempt. `openAppWhenRun` is true,
/// so the intent brings Conduit to the foreground and the model runs there.
/// Running a multi-gigabyte model inside the Shortcuts extension process
/// instead would be far more elegant and does not work: extensions get a much
/// tighter memory limit than the host app, and an 8B model is terminated
/// immediately. Foregrounding the app is the honest implementation.
struct AskConduitIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Conduit"

    static var description = IntentDescription(
        "Hand a task to Conduit's local model, such as adding a calendar event or drafting a text.",
        categoryName: "Tasks"
    )

    /// The model needs the foreground: see the note above.
    static var openAppWhenRun: Bool { true }

    @Parameter(
        title: "Task",
        description: "What you want done, in plain language.",
        requestValueDialog: "What should Conduit do?"
    )
    var task: String

    func perform() async throws -> some IntentResult {
        PendingTask.store(task)
        return .result()
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Conduit to \(\.$task)")
    }
}

/// Hands a task from the intent to the running app.
///
/// An intent with `openAppWhenRun` returns before the app's UI is ready, so
/// the task is parked here and collected by the root view on appear. A
/// timestamp guards against a stale task from a previous launch being replayed
/// days later, which would be a genuinely alarming thing for an app that can
/// write to your calendar.
enum PendingTask {
    private static let taskKey = "conduit.pendingTask"
    private static let stampKey = "conduit.pendingTaskAt"
    /// Anything older than this is discarded unrun.
    private static let maximumAge: TimeInterval = 60

    static func store(_ task: String) {
        UserDefaults.standard.set(task, forKey: taskKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: stampKey)
    }

    /// Returns the pending task once, then clears it.
    static func take() -> String? {
        defer {
            UserDefaults.standard.removeObject(forKey: taskKey)
            UserDefaults.standard.removeObject(forKey: stampKey)
        }
        guard let task = UserDefaults.standard.string(forKey: taskKey),
              !task.isEmpty
        else { return nil }

        let stamp = UserDefaults.standard.double(forKey: stampKey)
        guard stamp > 0, Date().timeIntervalSince1970 - stamp < maximumAge else { return nil }
        return task
    }
}

/// Siri phrases.
///
/// Every phrase must contain the app name — Siri requires it, and phrases
/// without it are silently dropped rather than reported as an error.
struct ConduitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskConduitIntent(),
            phrases: [
                "Ask \(.applicationName) to \(\.$task)",
                "Tell \(.applicationName) to \(\.$task)",
                "\(.applicationName) \(\.$task)",
            ],
            shortTitle: "Ask Conduit",
            systemImageName: "wand.and.sparkles"
        )
    }
}
