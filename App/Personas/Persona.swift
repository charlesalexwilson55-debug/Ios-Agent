import Foundation
import Observation
import SwiftUI
import UIKit

/// A custom personality: a name, a voice, a goal, the connectors it may use,
/// the model it prefers, a colour, and how hard it works.
struct Persona: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var jobTitle = ""
    var personality = ""
    var goal = ""
    /// Free text naming the connectors this personality uses, such as
    /// "calendar, web, maps". Read by `Connector.matches(in:)`.
    var connectors = ""
    /// Free text naming the model to switch to, matched against the models
    /// on the phone. Empty keeps whatever is loaded.
    var model = ""
    var colorHex = Persona.palette[0].hex
    var effort: Effort = .normal
    /// Answers written before the best is kept. Questions only: phone
    /// actions have side effects and are never drafted twice.
    var drafts = 1

    enum Effort: String, Codable, CaseIterable, Identifiable {
        case relaxed, normal, hard

        var id: String { rawValue }

        var title: String {
            switch self {
            case .relaxed: "Relaxed"
            case .normal: "Normal"
            case .hard: "Hard-working"
            }
        }

        var detail: String {
            switch self {
            case .relaxed:
                "Quick replies: never thinks first, takes at most 4 steps on a task, and "
                    + "researches lightly."
            case .normal:
                "Follows the Think switch and takes up to 6 steps on a task."
            case .hard:
                "Always thinks first, takes up to 12 steps on a task, and researches more pages. "
                    + "Slower."
            }
        }

        /// Tool calls allowed per request.
        var toolSteps: Int {
            switch self {
            case .relaxed: 4
            case .normal: 6
            case .hard: 12
            }
        }

        /// Overrides the Think switch, or nil to follow it.
        var thinking: Bool? {
            switch self {
            case .relaxed: return false
            case .normal: return nil
            case .hard: return true
            }
        }
    }

    struct Swatch: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let palette: [Swatch] = [
        Swatch(name: "Blue", hex: "#0A84FF"),
        Swatch(name: "Purple", hex: "#8E5CF7"),
        Swatch(name: "Pink", hex: "#FF4F9A"),
        Swatch(name: "Red", hex: "#FF453A"),
        Swatch(name: "Orange", hex: "#FF9F0A"),
        Swatch(name: "Yellow", hex: "#FFD60A"),
        Swatch(name: "Green", hex: "#30D158"),
        Swatch(name: "Teal", hex: "#40C8E0"),
        Swatch(name: "Brown", hex: "#AC8E68"),
        Swatch(name: "Graphite", hex: "#636366"),
    ]

    static let maxDrafts = 3
    /// Longest text kept from each box in the system prompt. The whole prompt
    /// is reprocessed every turn, so an essay here slows every reply.
    static let promptFieldLimit = 600

    var color: Color { Color(hex: colorHex) ?? .accentColor }

    var displayTitle: String {
        let title = jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? name : "\(name) \u{00B7} \(title)"
    }

    /// Tool names this personality may use, or nil for all of them.
    var allowedToolNames: Set<String>? {
        Connector.allowedToolNames(for: connectors)
    }

    /// The section added to the end of the system prompt.
    var promptSection: String {
        func clip(_ text: String) -> String {
            String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.promptFieldLimit))
        }
        var lines = ["# Your role"]
        let who = clip(name)
        let title = clip(jobTitle)
        if !who.isEmpty {
            lines.append(title.isEmpty ? "Your name is \(who)." : "Your name is \(who), and you work as \(title).")
        } else if !title.isEmpty {
            lines.append("You work as \(title).")
        }
        if !clip(personality).isEmpty {
            lines.append("Personality: \(clip(personality))")
        }
        if !clip(goal).isEmpty {
            lines.append("Main goal: \(clip(goal))")
        }
        lines.append("Speak in this role's voice, but the user's request always comes first: do "
            + "exactly what they ask, completely.")
        return lines.joined(separator: "\n")
    }
}

/// The connectors a personality can name. These are Conduit's built-in tool
/// groups: MCP servers cannot run inside an iOS app.
enum Connector: String, CaseIterable, Identifiable {
    case calendar, reminders, notifications, contacts, messages, web, maps, music, apps
    case clipboard, shortcuts, code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .notifications: "Notifications"
        case .contacts: "Contacts"
        case .messages: "Messages & calls"
        case .web: "Web"
        case .maps: "Maps"
        case .music: "Music"
        case .apps: "Apps"
        case .clipboard: "Clipboard"
        case .shortcuts: "Shortcuts"
        case .code: "Code & maths"
        }
    }

    /// The word added to the box when the suggestion is tapped.
    var keyword: String {
        switch self {
        case .messages: "messages"
        case .code: "code"
        default: rawValue
        }
    }

    private var vocabulary: Set<String> {
        switch self {
        case .calendar: return ["calendar", "calendars", "event", "events", "schedule", "meetings", "appointments"]
        case .reminders: return ["reminders", "reminder", "todo", "todos", "to-do", "tasks"]
        case .notifications: return ["notifications", "notification", "nudges", "alerts"]
        case .contacts: return ["contacts", "contact", "people"]
        case .messages: return ["messages", "messaging", "message", "texts", "text", "sms", "imessage",
                         "whatsapp", "email", "emails", "mail", "calls", "call", "phone", "facetime"]
        case .web: return ["web", "internet", "online", "search", "browser", "safari", "weather",
                    "tavily", "google", "websites"]
        case .maps: return ["maps", "map", "directions", "navigation", "travel"]
        case .music: return ["music", "songs", "spotify"]
        case .apps: return ["apps", "app"]
        case .clipboard: return ["clipboard", "copy"]
        case .shortcuts: return ["shortcuts", "shortcut", "automation", "automations"]
        case .code: return ["code", "javascript", "maths", "math", "calculator", "calculations"]
        }
    }

    var toolNames: Set<String> {
        switch self {
        case .calendar: return ["create_event", "find_events", "check_availability", "delete_event"]
        case .reminders: return ["create_reminder", "find_reminders", "complete_reminder"]
        case .notifications: return ["schedule_notification"]
        case .contacts: return ["find_contact", "remember_person_alias"]
        case .messages: return ["send_message", "send_email", "place_call", "find_contact", "remember_person_alias"]
        case .web: return ["web_search", "read_page", "get_weather", "open_in_browser"]
        case .maps: return ["get_directions"]
        case .music: return ["play_music"]
        case .apps: return ["open_app"]
        case .clipboard: return ["copy_to_clipboard"]
        case .shortcuts: return ["run_shortcut"]
        case .code: return ["run_javascript"]
        }
    }

    /// Always offered: the time for any date, and the calculator for maths.
    static let alwaysAllowed: Set<String> = ["get_current_time", "run_javascript"]

    private static let everything: Set<String> = ["all", "everything", "any", "anything"]

    static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "-" })
            .map(String.init)
    }

    /// The connectors named in the text, in the order of `allCases`.
    static func matches(in text: String) -> [Connector] {
        let found = Set(words(in: text))
        return allCases.filter { !$0.vocabulary.isDisjoint(with: found) }
    }

    /// Nil means no restriction: the box is empty, says "all", or names
    /// nothing recognisable.
    static func allowedToolNames(for text: String) -> Set<String>? {
        if !everything.isDisjoint(with: words(in: text)) { return nil }
        let connectors = matches(in: text)
        guard !connectors.isEmpty else { return nil }
        return connectors.reduce(into: alwaysAllowed) { $0.formUnion($1.toolNames) }
    }
}

/// The saved personalities and which one is in use.
@MainActor
@Observable
final class PersonaStore {
    static let shared = PersonaStore()

    private(set) var personas: [Persona] = []
    private(set) var selectedID: UUID?

    private static let listKey = "conduit.personas"
    private static let selectedKey = "conduit.persona.selected"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.listKey),
           let saved = try? JSONDecoder().decode([Persona].self, from: data) {
            personas = saved
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey),
           let id = UUID(uuidString: raw), personas.contains(where: { $0.id == id }) {
            selectedID = id
        }
    }

    /// The personality in use, or nil for plain Conduit.
    var selected: Persona? {
        personas.first { $0.id == selectedID }
    }

    func select(_ id: UUID?) {
        selectedID = id
        UserDefaults.standard.set(id?.uuidString, forKey: Self.selectedKey)
    }

    func save(_ persona: Persona) {
        var cleaned = persona
        cleaned.name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.drafts = min(max(persona.drafts, 1), Persona.maxDrafts)
        if let index = personas.firstIndex(where: { $0.id == persona.id }) {
            personas[index] = cleaned
        } else {
            personas.append(cleaned)
        }
        persist()
    }

    func delete(_ id: UUID) {
        personas.removeAll { $0.id == id }
        if selectedID == id { select(nil) }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(personas) {
            UserDefaults.standard.set(data, forKey: Self.listKey)
        }
    }
}

extension Color {
    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// "#RRGGBB" in sRGB, for saving a colour the user picked.
    var hexString: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
