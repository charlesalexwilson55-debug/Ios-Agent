import Foundation

/// Decides, per request, whether the model is answering a question or doing
/// something on the phone, and which tools it is offered.
///
/// A small model offered every phone tool treats every message as a phone
/// task: asked a plain question it reaches for tools, or answers like a
/// device assistant instead of from what it knows. Questions therefore get
/// the short answer prompt and only the tools that help answer. Tools that
/// are not offered cannot be called, which also means text read from a web
/// page can never trigger a message, a call or a deletion during a question.
enum TaskRouter {

    /// Tools offered when answering a question.
    static let answerToolNames: Set<String> = [
        "get_current_time", "run_javascript", "web_search", "read_page", "get_weather",
    ]

    /// Tools that reach the internet. Withheld when the user has switched
    /// online access off or there is no signal.
    static let webToolNames: Set<String> = ["web_search", "read_page", "get_weather"]

    static func mode(for request: String, previousTurnUsedPhoneTools: Bool) -> SystemPrompt.Mode {
        if looksLikePhoneTask(request) { return .task }
        // "Yes, the second one" or "make it 5pm" continues a phone task.
        if previousTurnUsedPhoneTools, wordCount(request) <= 8 { return .task }
        return .answer
    }

    static func tools(from all: [ToolDescriptor], mode: SystemPrompt.Mode, online: Bool) -> [ToolDescriptor] {
        all.filter { tool in
            if !online, webToolNames.contains(tool.name) { return false }
            switch mode {
            case .task: return true
            case .answer: return answerToolNames.contains(tool.name)
            }
        }
    }

    // MARK: - Detection

    /// Words that mean a phone task wherever they appear.
    private static let strongWords: Set<String> = [
        "calendar", "meeting", "meetings", "appointment", "appointments", "agenda", "diary",
        "reschedule", "remind", "reminder", "reminders", "alarm", "timer",
        "notification", "notifications", "shortcut", "shortcuts", "directions", "navigate",
        "contacts", "clipboard", "nickname", "facetime", "imessage", "whatsapp", "sms",
    ]

    /// Words that mean a phone task only when they start the request, as a
    /// command: "open Spotify", but not "what time does the museum open".
    private static let commandVerbs: Set<String> = [
        "text", "message", "msg", "call", "ring", "phone", "ping", "email", "mail", "send",
        "draft", "reply", "open", "launch", "play", "book", "schedule", "invite", "set",
        "add", "create", "delete", "cancel", "remove", "copy", "take", "drive", "get",
        "run", "start", "mark", "complete",
    ]

    /// Filler that can come before the command verb.
    private static let fillers: Set<String> = [
        "please", "pls", "can", "could", "would", "will", "you", "hey", "hi", "ok", "okay",
        "conduit", "quickly", "just", "go", "ahead", "and", "i", "want", "need", "to",
    ]

    private static let taskPhrases: [String] = [
        "how do i get to", "how do i get home", "take me to", "take me home", "get me to",
        "get me home", "am i free", "am i busy", "what's on my", "whats on my", "my schedule",
        "my day", "on my way",
    ]

    static func looksLikePhoneTask(_ request: String) -> Bool {
        let lowered = request.lowercased()
        let words = lowered
            .split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" })
            .map(String.init)
        if words.contains(where: { strongWords.contains($0) }) { return true }
        if taskPhrases.contains(where: { lowered.contains($0) }) { return true }

        let command = words.drop(while: { fillers.contains($0) })
        if let verb = command.first, commandVerbs.contains(verb) { return true }
        // "Tell Sam I'm late", but not "tell me about Rome".
        if command.first == "tell", let next = command.dropFirst().first,
           !["me", "us", "about"].contains(next) {
            return true
        }
        // "Let Sam know I'm running late."
        if command.first == "let", command.dropFirst().prefix(3).contains("know") {
            return true
        }
        return false
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
