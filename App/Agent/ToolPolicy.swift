import Foundation

/// Checks the model's tool choices against what the user actually said.
///
/// Small models over-reach with tools that leave the app. Asked a hard
/// question, Qwen3-4B would open a web search instead of answering, which
/// threw the user out to the browser mid-conversation. The prompt discourages
/// that, but a prompt is only a suggestion; this is a rule.
///
/// A refusal goes back to the model as a failed tool result telling it what
/// to do instead. The user never sees it.
enum ToolPolicy {

    static func refusal(for tool: String, request: String, previousReply: String) -> ToolOutcome? {
        switch tool {
        case "web_search":
            if mentionsAny(request, searchWords) || acceptsOffer(request, previousReply) {
                return nil
            }
            return .failure("web_search",
                "Not run: the user did not ask for a web search. Answer the question yourself, "
                    + "fully, from what you know. If it needs live information such as news, "
                    + "weather or prices, say you are offline and can open a web search if asked.")
        default:
            return nil
        }
    }

    private static let searchWords = [
        "search", "google", "look up", "look it up", "lookup", "look online", "online",
        "the web", "internet", "browse", "browser", "safari", "duckduckgo", "bing", "website",
    ]

    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "please", "go", "do",
    ]

    private static func mentionsAny(_ text: String, _ words: [String]) -> Bool {
        let lowered = text.lowercased()
        return words.contains { lowered.contains($0) }
    }

    /// "yes" or "go ahead" straight after the model offered to search.
    private static func acceptsOffer(_ request: String, _ previousReply: String) -> Bool {
        guard previousReply.lowercased().contains("search") else { return false }
        let words = request.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard let first = words.first, words.count <= 6 else { return false }
        return affirmatives.contains(first)
    }
}
