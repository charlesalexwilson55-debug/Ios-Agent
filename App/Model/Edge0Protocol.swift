import Foundation

/// Formats the text/tool conversation for a streaming backend and keeps protocol tags out of chat.
enum Edge0Protocol {
    struct Message {
        let role: String
        let content: String
        var calls: [(name: String, json: String)] = []
    }
    static func prompt(messages: [Message], schemas: [[String: Any]], thinking: Bool, small: Bool) throws -> String {
        var system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
        if !schemas.isEmpty {
            let tools = try schemas.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n")
            system += "\n# Tools\nYou can use these tools:\n<tools>\n\(tools)\n</tools>\n"
            if small {
                system += "To call a tool, output <tool_call>{\"name\":\"tool_name\",\"arguments\":{\"parameter\":\"value\"}}</tool_call>."
            } else {
                system += "To call a tool, output <tool_call>\n<function=tool_name>\n<parameter=parameter_name>\nvalue\n</parameter>\n</function>\n</tool_call>."
            }
            system += " Required parameters must be supplied. Only use offered tools. Do not claim an action happened until its tool result confirms it."
        }
        func wrap(_ role: String, _ content: String) -> String {
            if small {
                let name = role == "system" ? "SYSTEM" : role == "assistant" ? "ASSISTANT" : "HUMAN"
                return "<role>\(name)</role>\(content)<|role_end|>"
            }
            return "<|im_start|>\(role)\n\(content)<|im_end|>\n"
        }
        var out = wrap("system", small ? "detailed thinking \(thinking ? "on" : "off")\n\(system)" : system)
        for message in messages where message.role != "system" {
            var content = message.content
            if message.role == "assistant" {
                for call in message.calls {
                    if small {
                        content += "\n<tool_call>{\"name\":\"\(call.name)\",\"arguments\":\(call.json)}</tool_call>"
                    } else {
                        content += "\n<tool_call>\n<function=\(call.name)>"
                        let values = try JSONSerialization.jsonObject(with: Data(call.json.utf8)) as? [String: Any] ?? [:]
                        for key in values.keys.sorted() {
                            let value: String
                            if let string = values[key] as? String { value = string }
                            else { value = String(decoding: try JSONSerialization.data(withJSONObject: values[key]!, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self) }
                            content += "\n<parameter=\(key)>\n\(value)\n</parameter>"
                        }
                        content += "\n</function>\n</tool_call>"
                    }
                }
            }
            if message.role == "tool" { content = "<tool_response>\n\(content)\n</tool_response>" }
            out += wrap(message.role == "tool" ? "user" : message.role, content)
        }
        out += small ? "<role>ASSISTANT</role>\n" : "<|im_start|>assistant\n"
        out += thinking ? "<think>\n" : "<think>\n\n</think>\n\n"
        return out
    }
    enum Piece { case text(String), reasoning(String), call(String, Data) }
    struct Parser {
        private(set) var hasCompleteCall = false
        private var buffer = ""
        private var reasoning: Bool
        private var tool = false
        init(thinking: Bool) { reasoning = thinking }
        mutating func feed(_ chunk: String, final: Bool = false) throws -> [Piece] {
            buffer += chunk
            var pieces: [Piece] = []
            while !buffer.isEmpty {
                if tool {
                    guard let end = buffer.range(of: "</tool_call>") else {
                        if final { throw Edge0Packing.Failure(message: "The model produced an incomplete tool call. Try again.") }
                        break
                    }
                    let body = String(buffer[..<end.lowerBound])
                    let call = try Self.call(body)
                    pieces.append(.call(call.0, call.1))
                    hasCompleteCall = true
                    buffer = String(buffer[end.upperBound...]); tool = false
                    continue
                }
                let tags = ["<think>", "</think>", "<tool_call>", "<|im_end|>", "<|role_end|>"]
                let match = tags.compactMap { tag in buffer.range(of: tag).map { (tag, $0) } }.min { $0.1.lowerBound < $1.1.lowerBound }
                if let (tag, range) = match {
                    let before = String(buffer[..<range.lowerBound])
                    if !before.isEmpty { pieces.append(reasoning ? .reasoning(before) : .text(before)) }
                    buffer = String(buffer[range.upperBound...])
                    if tag == "<think>" { reasoning = true }
                    if tag == "</think>" { reasoning = false }
                    if tag == "<tool_call>" { tool = true }
                    continue
                }
                var keep = 0
                for tag in tags {
                    for length in 1..<tag.count where buffer.hasSuffix(String(tag.prefix(length))) { keep = max(keep, length) }
                }
                let text = String(buffer.dropLast(keep))
                if !text.isEmpty { pieces.append(reasoning ? .reasoning(text) : .text(text)) }
                buffer = keep == 0 ? "" : String(buffer.suffix(keep))
                break
            }
            if final { buffer = "" }
            return pieces
        }
        private static func call(_ text: String) throws -> (String, Data) {
            if let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = object["name"] as? String, let arguments = object["arguments"] as? [String: Any] {
                return (name, try JSONSerialization.data(withJSONObject: arguments))
            }
            // Qwen's published XML function format is also accepted.
            guard let function = text.range(of: #"<function=([^>]+)>"#, options: .regularExpression), text.contains("</function>") else {
                throw Edge0Packing.Failure(message: "The model produced an invalid tool call.")
            }
            let name = String(text[function]).dropFirst(10).dropLast()
            let regex = try NSRegularExpression(pattern: #"<parameter=([^>]+)>\s*([\s\S]*?)\s*</parameter>"#)
            let ns = text as NSString
            var arguments: [String: Any] = [:]
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: match.range(at: 1))
                let raw = ns.substring(with: match.range(at: 2))
                if let data = raw.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    arguments[key] = value
                } else { arguments[key] = raw }
            }
            return (String(name), try JSONSerialization.data(withJSONObject: arguments))
        }
    }
}
