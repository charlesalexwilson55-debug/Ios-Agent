import Foundation

/// Research mode is a preference, not permission to turn every utterance into
/// a new subject. User corrections stay in conversation and remain unverified.
enum ResearchTurnRouter {
    enum Route: Equatable, Sendable {
        case conversation
        case correction
        case research(String)
    }

    static func route(_ message: String, enabled: Bool, previousRequest: String?) -> Route {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let words = ResearchPlan.words(text)
        guard !words.isEmpty else { return .conversation }
        let explicit = #"^(?:(?:please|can you|could you)\s+)*(?:research|investigate|look into|find information (?:on|about)|search for|look up)\b"#
        if lower.range(of: explicit, options: .regularExpression) != nil { return .research(text) }
        let correction = #"^(?:(?:actually|correction|no|nope)[,:]?\s+)?(?:(?:he|she|they|it|[\p{L}'’-]+(?:\s+[\p{L}'’-]+){0,4})\s+(?:is|isn't|is not|are|aren't|was|wasn't|lives in|works at|uses)\s+(?:(?:a|an|the)\s+)?(?:boy|girl|man|woman|male|female|he|she|they|not|from|based|called|named)\b|(?:he|she|they)\s+(?:lives in|works at)\b)"#
        if lower.range(of: correction, options: .regularExpression) != nil
            || lower.hasPrefix("actually ") || lower.hasPrefix("correction:")
            || lower.hasPrefix("i meant ") || lower.hasPrefix("that's wrong") {
            return .correction
        }
        if previousRequest != nil, !text.hasSuffix("?"), words.count <= 20,
           !["what", "who", "why", "when", "where", "how", "is", "are"].contains(words[0]),
           lower.range(of: #"^[\p{L}'’-]+(?:\s+[\p{L}'’-]+){0,4}\s+(?:is|isn't|are|was|lives in|works at)\s+.+$"#, options: .regularExpression) != nil {
            return .correction
        }
        if ["open", "call", "text", "message", "send", "remind", "create", "write", "calculate", "draw", "generate"].contains(words[0]) { return .conversation }
        let followups = ["find more", "keep looking", "keep searching", "continue researching", "continue", "what else", "more information", "any other sources"]
        if enabled, let previousRequest, followups.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower == $0 + "?" }) {
            return .research(previousRequest + "\nResearch goal: find additional public information and independent sources.")
        }
        let conversational = ["thanks", "thank you", "okay", "ok", "yes", "no", "stop", "hello", "hi", "can you hear me", "what do you mean", "why did you", "why are you", "what did you find", "explain that", "summarise", "summarize", "how does this app", "can you do", "you got", "that is wrong", "that's not"]
        if conversational.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + "?") || lower.hasPrefix($0 + ".") }) { return .conversation }
        // A full sentence asking the assistant to change its behaviour is not
        // a name or a topic. Ordinary chat can still use web tools if needed.
        if words.contains("you") || words.contains("your") || words.first == "i" { return .conversation }
        if enabled { return .research(text) }
        return .conversation
    }
}
