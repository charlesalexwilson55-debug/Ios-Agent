import Foundation

/// Assembles every provider into one namespace and dispatches by tool name.
///
/// Dispatch is by string rather than by a Swift enum so that a name the model
/// invents produces a readable error listing the real names, which the model
/// can act on. An enum would fail to decode and the turn would die silently.
@MainActor
final class ToolRegistry {
    private let providers: [ToolProviding]
    private let index: [String: ToolProviding]
    /// Providers whose tools change while the app runs, such as MCP servers
    /// the user adds. Looked up on every call instead of indexed.
    private let dynamicProviders: [ToolProviding]

    init(providers: [ToolProviding], dynamicProviders: [ToolProviding] = []) {
        self.providers = providers
        self.dynamicProviders = dynamicProviders
        var index: [String: ToolProviding] = [:]
        for provider in providers {
            for spec in provider.specs {
                // A duplicate name means two providers silently compete; the
                // first registration wins and the collision is worth knowing
                // about during development.
                assert(index[spec.name] == nil, "Duplicate tool name: \(spec.name)")
                index[spec.name] = provider
            }
        }
        self.index = index
    }

    static func standard() -> ToolRegistry {
        ToolRegistry(providers: [
            PeopleTools(),
            CalendarTools(),
            DeviceTools(),
            CodeTools(),
            WebTools(),
        ], dynamicProviders: [
            MCPTools(),
        ])
    }

    var specs: [ToolDescriptor] { (providers + dynamicProviders).flatMap { $0.specs } }

    func spec(named name: String) -> ToolDescriptor? {
        specs.first { $0.name == name }
    }

    func run(_ name: String, arguments: ArgumentValue) async -> ToolOutcome {
        let dynamic = dynamicProviders.first { provider in
            provider.specs.contains { $0.name == name }
        }
        guard let provider = index[name] ?? dynamic else {
            let available = specs.map(\.name).sorted().joined(separator: ", ")
            return .failure(name, "There is no tool called \(name). "
                + "The available tools are: \(available). Pick one of those.")
        }
        return await provider.run(name, arguments: arguments)
    }
}

// MARK: - Dates

/// Date handling for tool arguments.
///
/// The model is told to emit local ISO 8601 and to call `get_current_time`
/// before any relative reasoning, because a language model has no clock and
/// will otherwise anchor on a date from its training data — producing events
/// silently scheduled in the wrong year. The extra formats below are accepted
/// because models drop the seconds or the `T` often enough that rejecting
/// those would cost a turn for no reason.
enum DateParsing {
    private static let formats = [
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
    ]

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        for format in formats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            if let date = f.date(from: trimmed) { return date }
        }
        return nil
    }

    /// For text shown to the user, in their locale.
    static func display(_ date: Date, includeTime: Bool = true) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = .current
        f.dateStyle = .medium
        f.timeStyle = includeTime ? .short : .none
        return f.string(from: date)
    }

    /// For text handed back to the model. Unambiguous and machine-readable, so
    /// the model can do arithmetic on it without reparsing a localised string.
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    /// The expected-format string used in every argument description, kept in
    /// one place so the tool schemas cannot drift from the parser.
    static let expectedFormat = "local ISO 8601, for example 2026-09-16T15:30:00"
}
