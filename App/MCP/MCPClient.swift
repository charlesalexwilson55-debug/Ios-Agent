import Foundation

/// A minimal client for remote MCP servers over the Streamable HTTP transport.
///
/// An iPhone app cannot start local MCP servers (there are no subprocesses on
/// iOS), but it can talk to servers on the internet. This covers what the
/// agent needs: `initialize`, `tools/list` and `tools/call`, with an optional
/// bearer token. Servers that only offer the older SSE transport, or that need
/// an OAuth sign-in, are not supported.
actor MCPClient {

    struct Tool: Codable, Hashable {
        let name: String
        let description: String
        /// The tool's input JSON Schema, kept as JSON text so it can be stored.
        let inputSchema: String
    }

    struct CallResult {
        let text: String
        let isError: Bool
    }

    enum MCPError: LocalizedError {
        case badURL
        case http(Int, String)
        case rpc(String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .badURL: "The server address is not a valid https:// link."
            case .http(401, _), .http(403, _):
                "The server refused the connection. Check the access token."
            case .http(let status, let body):
                "The server answered with error \(status)." + (body.isEmpty ? "" : " \(body)")
            case .rpc(let message): "The server reported an error: \(message)"
            case .badResponse(let why): "The server sent something unexpected (\(why))."
            }
        }
    }

    static let protocolVersion = "2025-06-18"
    private static let timeout: TimeInterval = 30

    private let endpoint: URL
    private let token: String?
    private var sessionID: String?
    private var negotiatedVersion: String?
    private var nextID = 1
    private var initialized = false

    init(url: String, token: String?) throws {
        guard let endpoint = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = endpoint.scheme?.lowercased(), scheme == "https" || scheme == "http",
              endpoint.host != nil
        else { throw MCPError.badURL }
        self.endpoint = endpoint
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.token = trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Operations

    func listTools(limit: Int) async throws -> [Tool] {
        try await ensureInitialized()
        var tools: [Tool] = []
        var cursor: String?
        // A few pages at most: a server with hundreds of tools would not fit
        // in a phone model's prompt anyway.
        for _ in 0..<5 {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await request("tools/list", params: params)
            for item in result["tools"] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String else { continue }
                let schema = item["inputSchema"] as? [String: Any] ?? ["type": "object"]
                let schemaData = (try? JSONSerialization.data(withJSONObject: schema)) ?? Data("{}".utf8)
                tools.append(Tool(
                    name: name,
                    description: (item["description"] as? String) ?? (item["title"] as? String) ?? "",
                    inputSchema: String(decoding: schemaData, as: UTF8.self)
                ))
                if tools.count >= limit { return tools }
            }
            cursor = result["nextCursor"] as? String
            if cursor == nil { break }
        }
        return tools
    }

    func callTool(_ name: String, arguments: Any) async throws -> CallResult {
        try await ensureInitialized()
        let result = try await request("tools/call", params: ["name": name, "arguments": arguments])
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { parts.append(text) }
            case "resource":
                if let resource = item["resource"] as? [String: Any], let text = resource["text"] as? String {
                    parts.append(text)
                }
            case "resource_link":
                let title = (item["name"] as? String) ?? "link"
                parts.append("\(title): \((item["uri"] as? String) ?? "")")
            case let other?:
                parts.append("[\(other) content not shown]")
            case nil:
                continue
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        return CallResult(text: parts.joined(separator: "\n"), isError: (result["isError"] as? Bool) ?? false)
    }

    // MARK: - Protocol

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        let result = try await request("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Conduit", "version": "0.1"],
        ], allowReinitialize: false)
        negotiatedVersion = (result["protocolVersion"] as? String) ?? Self.protocolVersion
        try await notify("notifications/initialized")
        initialized = true
    }

    private func notify(_ method: String) async throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        let (_, response) = try await send(body)
        guard (200..<300).contains(response.statusCode) else {
            throw MCPError.http(response.statusCode, "")
        }
    }

    private func request(
        _ method: String,
        params: [String: Any],
        allowReinitialize: Bool = true
    ) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { body["params"] = params }

        let (data, response) = try await send(body)
        // An expired session: start a new one and try once more.
        if response.statusCode == 404, sessionID != nil, allowReinitialize {
            sessionID = nil
            initialized = false
            try await ensureInitialized()
            return try await request(method, params: params, allowReinitialize: false)
        }
        if method == "initialize", let session = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = session
        }
        guard (200..<300).contains(response.statusCode) else {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MCPError.http(response.statusCode, snippet)
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let messages: [[String: Any]]
        if contentType.contains("text/event-stream") {
            messages = Self.eventStreamMessages(data)
        } else {
            let single = try Self.jsonObject(data)
            messages = single.map { [$0] } ?? []
        }
        guard let reply = messages.first(where: { Self.matches($0["id"], id) }) else {
            throw MCPError.badResponse("no reply to \(method)")
        }
        if let error = reply["error"] as? [String: Any] {
            throw MCPError.rpc((error["message"] as? String) ?? "unknown error")
        }
        guard let result = reply["result"] as? [String: Any] else {
            throw MCPError.badResponse("reply to \(method) had no result")
        }
        return result
    }

    private func send(_ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiatedVersion {
            request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.badResponse("not an HTTP response")
        }
        return (data, http)
    }

    // MARK: - Parsing

    private static func jsonObject(_ data: Data) throws -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw MCPError.badResponse("not JSON")
        }
        return object as? [String: Any]
    }

    /// The JSON messages in a server-sent event stream: each event's `data:`
    /// lines joined, one message per event.
    static func eventStreamMessages(_ data: Data) -> [[String: Any]] {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var messages: [[String: Any]] = []
        var dataLines: [String] = []
        func flush() {
            defer { dataLines = [] }
            guard !dataLines.isEmpty,
                  let payload = dataLines.joined(separator: "\n").data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { return }
            messages.append(object)
        }
        for line in text.components(separatedBy: "\n") {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                dataLines.append(value)
            }
        }
        flush()
        return messages
    }

    private static func matches(_ value: Any?, _ id: Int) -> Bool {
        if let number = value as? Int { return number == id }
        if let number = value as? Double { return Int(number) == id }
        if let text = value as? String { return text == String(id) }
        return false
    }
}
