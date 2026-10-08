import Foundation

/// Small, explicit routes. Tool-using requests stay with the chat model because
/// MiniCPM5's tool syntax is not supported by the pinned MLX Swift parser.
enum ModelTaskRouter {
    enum Role: String, CaseIterable, Identifiable {
        case quickText, researchCheck, heavy, chat
        var id: String { rawValue }
    }
    static let enabledKey = "conduit.models.autoRouting"
    static func role(for request: String, research: Bool) -> Role {
        if research { return .researchCheck }
        let lower = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let resources: Set<String> = ["photo", "photos", "image", "images", "library", "libraries", "calendar", "email", "message", "messages", "send", "call", "search", "research", "weather", "website", "file", "files", "document", "documents", "notes", "remember"]
        if !words.isDisjoint(with: resources) || lower.contains("http") { return .chat }
        let heavy: Set<String> = ["debug", "refactor", "implement", "algorithm", "prove", "proof"]
        if !words.isDisjoint(with: heavy) || lower.contains("write code") || lower.contains("write a program") { return .heavy }
        if ["hello", "hi", "hey"].contains(lower) { return .quickText }
        if ["rewrite this", "translate this", "rephrase this"].contains(where: lower.hasPrefix),
           lower.count < 2_000 { return .quickText }
        return .chat
    }
}
