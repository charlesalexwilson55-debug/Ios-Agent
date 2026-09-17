import Foundation
import Observation

/// One exchange in a saved chat: what was asked, how the model worked it
/// out, what it did, and what it said.
struct ThoughtRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var request: String
    /// The model's own thinking, when Think was on.
    var reasoning: String
    /// One line per tool it used, as shown in the chat.
    var actions: [String]
    var answer: String
}

/// A saved chat.
struct ChatRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var created: Date
    var updated: Date
    var personaName: String?
    var personaColorHex: String?
    var thoughts: [ThoughtRecord]
}

/// The memory bank: every chat, kept on the phone, and indexed so later
/// chats can look back at what was said and worked out before.
@MainActor
@Observable
final class ConversationStore {
    static let shared = ConversationStore()

    /// Newest first.
    private(set) var chats: [ChatRecord] = []

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        chats = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ChatRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    static func collection(for chatID: UUID) -> String { "chat:\(chatID.uuidString)" }

    /// Saves one exchange and indexes it for recall.
    func record(chatID: UUID, thought: ThoughtRecord, persona: Persona?) {
        var chat = chats.first { $0.id == chatID } ?? ChatRecord(
            id: chatID,
            title: Self.title(from: thought.request),
            created: thought.date,
            updated: thought.date,
            personaName: persona?.name,
            personaColorHex: persona?.colorHex,
            thoughts: []
        )
        chat.thoughts.append(thought)
        chat.updated = thought.date
        if let persona {
            chat.personaName = persona.name
            chat.personaColorHex = persona.colorHex
        }
        chats.removeAll { $0.id == chatID }
        chats.insert(chat, at: 0)
        save(chat)

        let title = chat.title
        let text = Self.indexText(thought)
        Task {
            try? await KnowledgeIndex.shared.add(
                id: "\(Self.collection(for: chatID))/\(thought.id.uuidString)",
                source: .memory,
                collection: Self.collection(for: chatID),
                title: title,
                text: text
            )
        }
    }

    func delete(_ chatID: UUID) {
        chats.removeAll { $0.id == chatID }
        try? FileManager.default.removeItem(at: Self.file(chatID))
        Task { try? await KnowledgeIndex.shared.remove(collection: Self.collection(for: chatID)) }
    }

    func chat(_ id: UUID) -> ChatRecord? {
        chats.first { $0.id == id }
    }

    // MARK: - Linking

    struct ThoughtLink: Hashable {
        let chatID: UUID
        let thoughtID: UUID
    }

    /// Every thought across every chat, oldest first. Each one's neighbours
    /// in this list are the thoughts before and after it.
    var timeline: [ThoughtLink] {
        chats
            .flatMap { chat in chat.thoughts.map { (chat.id, $0) } }
            .sorted { $0.1.date < $1.1.date }
            .map { ThoughtLink(chatID: $0.0, thoughtID: $0.1.id) }
    }

    func neighbours(of link: ThoughtLink) -> (previous: ThoughtLink?, next: ThoughtLink?) {
        let all = timeline
        guard let index = all.firstIndex(of: link) else { return (nil, nil) }
        return (index > 0 ? all[index - 1] : nil, index + 1 < all.count ? all[index + 1] : nil)
    }

    func thought(_ link: ThoughtLink) -> (chat: ChatRecord, thought: ThoughtRecord)? {
        guard let record = self.chat(link.chatID),
              let thought = record.thoughts.first(where: { $0.id == link.thoughtID })
        else { return nil }
        return (record, thought)
    }

    // MARK: - Files

    private static func file(_ id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    private func save(_ chat: ChatRecord) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(chat) else { return }
        try? data.write(to: Self.file(chat.id), options: .atomic)
    }

    static func title(from request: String) -> String {
        let line = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? request
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "\u{2026}" : trimmed
    }

    private static func indexText(_ thought: ThoughtRecord) -> String {
        var parts = ["The user asked: \(thought.request)"]
        if !thought.reasoning.isEmpty { parts.append("Thinking: \(thought.reasoning)") }
        if !thought.actions.isEmpty { parts.append("Actions: " + thought.actions.joined(separator: "; ")) }
        parts.append("Answer: \(thought.answer)")
        return parts.joined(separator: "\n")
    }
}
