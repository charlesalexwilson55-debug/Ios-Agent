import Foundation

/// A minimal JSON value. Tool arguments arrive from the model as untyped JSON;
/// decoding straight into per-tool structs would mean one `Codable` type per
/// tool and a failure mode ("could not decode") that tells the model nothing
/// it can act on. Keeping arguments loose lets each tool report *which* field
/// was wrong, which is what actually gets a retry to succeed.
enum ArgumentValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([ArgumentValue])
    case object([String: ArgumentValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([ArgumentValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: ArgumentValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    static func parse(_ raw: String) -> ArgumentValue {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(ArgumentValue.self, from: data)
        else { return .object([:]) }
        return value
    }
}

/// Typed accessors. Models routinely send "true" for a boolean and "3" for a
/// number, so each accessor coerces across the obvious representations rather
/// than failing. A strict read here turns a basically-correct tool call into a
/// dead turn.
extension ArgumentValue {
    subscript(key: String) -> ArgumentValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    var stringValue: String? {
        switch self {
        case .string(let v): return v
        case .number(let v): return v == v.rounded() ? String(Int(v)) : String(v)
        case .bool(let v): return String(v)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let v): return v
        case .string(let v): return Double(v)
        case .bool(let v): return v ? 1 : 0
        default: return nil
        }
    }

    var intValue: Int? { doubleValue.map { Int($0) } }

    var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .number(let v): return v != 0
        case .string(let v):
            switch v.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    var arrayValue: [ArgumentValue]? {
        switch self {
        case .array(let v): return v
        // A single value where a list was expected is a very common model slip
        // and is unambiguous to repair.
        case .string, .number, .bool: return [self]
        default: return nil
        }
    }

    func string(_ key: String) -> String? { self[key]?.stringValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func strings(_ key: String) -> [String]? {
        self[key]?.arrayValue?.compactMap { $0.stringValue }
    }
}

// MARK: - Tool declaration

enum ToolParamType: String {
    case string, number, integer, boolean, array, object
}

struct ToolParam {
    let name: String
    let type: ToolParamType
    let description: String
    var required: Bool = false
    /// Constrains the model to a fixed set. Worth using aggressively: an enum
    /// is the difference between "calendar" and "the Calendar app".
    var allowedValues: [String]?
    /// Element type when `type == .array`.
    var elementType: ToolParamType?

    static func required(_ name: String, _ type: ToolParamType, _ description: String,
                         allowedValues: [String]? = nil,
                         elementType: ToolParamType? = nil) -> ToolParam {
        ToolParam(name: name, type: type, description: description, required: true,
                  allowedValues: allowedValues, elementType: elementType)
    }

    static func optional(_ name: String, _ type: ToolParamType, _ description: String,
                         allowedValues: [String]? = nil,
                         elementType: ToolParamType? = nil) -> ToolParam {
        ToolParam(name: name, type: type, description: description, required: false,
                  allowedValues: allowedValues, elementType: elementType)
    }
}

/// How much friction iOS imposes on a tool, independent of anything the model
/// does. Surfaced in the UI and in the system prompt so the model can tell the
/// user the truth ("drafted it, tap send") instead of claiming a send it cannot
/// perform.
enum ToolFriction: String, Codable {
    /// Runs to completion with no user interaction (permission prompt aside).
    case silent
    /// Presents a system sheet the user must confirm. iOS provides no way
    /// around this, and no amount of local inference changes it.
    case requiresConfirmation
    /// Hands off to another app; Conduit goes to the background.
    case leavesApp
}

struct ToolDescriptor {
    let name: String
    let description: String
    var params: [ToolParam] = []
    var friction: ToolFriction = .silent
    /// Grouping for the permissions/capability UI.
    var category: String = "general"
    /// A JSON Schema supplied as is, for tools described by someone else
    /// (MCP servers). Used instead of `params` when set.
    var rawParameters: [String: any Sendable]?

    /// JSON Schema for this tool's arguments.
    ///
    /// Typed as `[String: any Sendable]` rather than `[String: Any]` because
    /// that is MLXLMCommon's `ToolSpec`, so the dictionary can be handed to
    /// `UserInput(tools:)` with no bridging step.
    var parameterSchema: [String: any Sendable] {
        if let rawParameters { return rawParameters }
        var properties: [String: any Sendable] = [:]
        var required: [String] = []
        for p in params {
            var entry: [String: any Sendable] = [
                "type": p.type.rawValue,
                "description": p.description,
            ]
            if let allowed = p.allowedValues { entry["enum"] = allowed }
            if p.type == .array {
                entry["items"] = ["type": (p.elementType ?? .string).rawValue] as [String: any Sendable]
            }
            properties[p.name] = entry
            if p.required { required.append(p.name) }
        }
        return ["type": "object", "properties": properties, "required": required]
    }

    /// The full OpenAI-style function wrapper that chat templates expect.
    ///
    /// Qwen's template reads `tools` as a list of objects each shaped
    /// `{type: "function", function: {name, description, parameters}}` and
    /// renders them into the system turn itself. Passing a bare parameter
    /// schema produces a prompt with no tool names in it, and a model that
    /// then calls nothing.
    var functionSchema: [String: any Sendable] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameterSchema,
            ] as [String: any Sendable],
        ]
    }
}

// MARK: - Tool results

/// The result shape every tool returns.
///
/// Deliberately not `throws`: a thrown Swift error ends the agent turn, but a
/// *failed* tool call is ordinary conversation, and the model should read the
/// failure and choose differently. So failures come back as values, with
/// `error` carrying text written for the model rather than for a log.
/// How finished a successful tool call actually is.
///
/// Three states rather than two, because "not done" has two distinct shapes on
/// iOS and the model must report them differently:
///
/// - `.completed` — it happened. Say so.
/// - `.awaitingUser` — staged in a system sheet; the user must tap send. The
///   task is NOT done, and someone needs to act.
/// - `.handedOff` — another app owns it now and Conduit cannot observe the
///   result. Nobody needs to act, but no outcome can be claimed either.
///
/// Collapsing the last two into one flag made the model say "tap send" about
/// running a shortcut, which is wrong in a way that erodes trust in everything
/// else it reports.
enum ToolCompletion {
    case completed
    case awaitingUser
    case handedOff
}

struct ToolOutcome {
    var ok: Bool
    var action: String
    /// One line for the transcript, written for the user.
    var summary: String
    /// Structured fields fed back to the model as its tool response.
    var detail: [String: String] = [:]
    /// Written for the model: say what was wrong AND what to try instead.
    var error: String?
    var completion: ToolCompletion = .completed

    static func success(_ action: String, _ summary: String,
                        detail: [String: String] = [:]) -> ToolOutcome {
        ToolOutcome(ok: true, action: action, summary: summary, detail: detail, error: nil)
    }

    /// Staged in a system sheet. The user still has to finish it.
    static func staged(_ action: String, _ summary: String,
                       detail: [String: String] = [:]) -> ToolOutcome {
        ToolOutcome(ok: true, action: action, summary: summary, detail: detail,
                    error: nil, completion: .awaitingUser)
    }

    /// Handed to another app. Conduit is now in the background and cannot see
    /// what happened next.
    static func handedOff(_ action: String, _ summary: String,
                          detail: [String: String] = [:]) -> ToolOutcome {
        ToolOutcome(ok: true, action: action, summary: summary, detail: detail,
                    error: nil, completion: .handedOff)
    }

    static func failure(_ action: String, _ error: String,
                        detail: [String: String] = [:]) -> ToolOutcome {
        ToolOutcome(ok: false, action: action, summary: error, detail: detail, error: error)
    }

    /// Missing or malformed argument. Names the field so the retry is targeted.
    static func badArgument(_ action: String, _ field: String, _ expected: String) -> ToolOutcome {
        .failure(action, "The \(field) argument was missing or invalid. Expected \(expected).")
    }

    /// Denied permission is terminal for the turn: retrying calls the same API
    /// and gets the same denial, so say so explicitly.
    static func denied(_ action: String, _ what: String) -> ToolOutcome {
        .failure(action, "Permission to access \(what) was denied. Do not retry this tool. "
            + "Tell the user they can grant access in Settings, under Privacy and Security.")
    }

    /// The payload handed back to the model as the tool response.
    var modelResponseJSON: String {
        var payload: [String: Any] = ["ok": ok, "action": action]
        if let error { payload["error"] = error }
        switch completion {
        case .completed:
            break
        case .awaitingUser:
            payload["status"] = "awaiting_user_confirmation"
            payload["note"] = "Staged in a system sheet. The user must tap send. "
                + "Do not claim it was sent. Tell them it is drafted and waiting for them."
        case .handedOff:
            payload["status"] = "handed_off"
            payload["note"] = "Another app is now open and Conduit cannot see what happens there. "
                + "Tell the user which app you opened and why, for example: I've opened Maps "
                + "with directions to the station. Do not claim it succeeded, "
                + "and do not tell the user to tap send - there is nothing for them to send."
        }
        for (k, v) in detail { payload[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{\"ok\":false,\"error\":\"result could not be encoded\"}" }
        return text
    }
}

/// Implemented by anything that contributes tools to the agent.
///
/// Main-actor isolated because every provider touches UIKit or a framework
/// singleton (EventKit's store, `CNContactStore`, compose sheets). Declaring
/// that here rather than on each conformer keeps the isolation explicit in the
/// contract; without it, a `@MainActor` class conforming to a non-isolated
/// protocol is a warning under Swift 5 and an error under Swift 6.
@MainActor
protocol ToolProviding {
    var specs: [ToolDescriptor] { get }
    func run(_ name: String, arguments: ArgumentValue) async -> ToolOutcome
}
