import Foundation

/// Model planning is an optional enhancement. The user's request remains the
/// source of truth and remains searchable when structured generation fails.
enum ResearchPlanner {
    static func make(request: String, reply: String) -> ResearchPlan {
        var fields: [String: [String]] = [:]
        func add(_ label: String, _ value: String) {
            let label = label.lowercased().replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            if !value.isEmpty { fields[label, default: []].append(value) }
        }
        // JSON and fenced JSON are common even when the prompt asks for lines.
        if let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start <= end,
           let data = String(reply[start...end]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in object {
                if let value = value as? String { add(key, value) }
                if let values = value as? [String] { for value in values { add(key, value) } }
            }
        }
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: #"^\s*(?:[-*•]|\d+[.)])\s*"#, with: "", options: .regularExpression)
            if let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) {
                add(String(line[..<separator]), String(line[line.index(after: separator)...]))
            }
        }
        func values(_ labels: [String]) -> [String] {
            labels.flatMap { fields[$0] ?? [] }.filter { ResearchPlan.contains($0, in: request) }
        }
        let names = values(["name", "full name", "person", "subject", "person name"])
        let explicitName = names.compactMap(cleanName).first
        let fallbackName = requestName(request)
        let personWords: Set<String> = ["person", "someone", "named", "called", "aged", "doctor", "dr", "surgeon", "professor", "employer"]
        let looksLikePerson = ResearchPlan.words(request).contains { personWords.contains($0) } || fallbackName != nil
        let topicSignals: Set<String> = ["models", "algorithms", "weather", "climate", "history", "technology", "physics", "compare", "best"]
        let explicitTopic = (fields["name"] ?? []).contains { $0.lowercased() == "none" }
            && !looksLikePerson && ResearchPlan.words(request).contains { topicSignals.contains($0) }
        // A model may truncate a longer supplied name. Prefer the recovered
        // request name when the proposed name is only a subset of it.
        // User words outrank model extraction. A small model once converted
        // "Kokoda Mitchell" into the unrelated topic "Kokoda Track".
        let name = explicitTopic ? nil : (fallbackName ?? explicitName)
        let clues = values(["location", "locations", "city", "town", "employer", "organisation", "organization", "company", "institution"])
            + requestClues(request)
        let keywords = values(["keyword", "keywords", "occupation", "profession", "role"])
            + (name.map { [$0] } ?? []) + clues
        // NONE is not permission to relax person matching. Unknown subject stays
        // discovery-only, using the complete request, until the user picks a page.
        var seen = Set<String>()
        let unique = keywords.filter { seen.insert(ResearchPlan.normalized($0)).inserted }
        return ResearchPlan(request: request, subject: name, keywords: unique, identityClues: clues, isTopic: explicitTopic)
    }

    private static let prefixes = #"^(?:(?:please|can you|could you|i want you to)\s+)*(?:(?:do|conduct|carry out)\s+)?(?:(?:some|a)\s+)?(?:(?:research|researcg|reserach|find information about|find information on|find info on|find out about|search for|look up|tell me about|who is|find)\s+)?(?:(?:on|about|for)\s+)?(?:(?:a|the)\s+)?(?:(?:doctor|dr\.?|professor|prof\.?)\s+)?"#

    /// Conservative extraction from the request itself. It need not handle every
    /// natural-language form: unknown forms still produce discovery searches.
    static func requestName(_ request: String) -> String? {
        for pattern in [#"(?i)\b(?:full name|name|named|called)\s*[:=]?\s+([^,;\n]+)"#,
                        #"[“\"]([^”\"]+)[”\"]"#] {
            if let captured = capture(pattern, in: request), let name = cleanName(captured) { return name }
        }
        let remainder = request.replacingOccurrences(of: prefixes, with: "", options: [.regularExpression, .caseInsensitive])
        return cleanName(remainder)
    }

    private static func cleanName(_ value: String) -> String? {
        let untitled = value.replacingOccurrences(of: #"(?i)^(?:dr\.?|doctor|prof\.?|professor)\s+"#, with: "", options: .regularExpression)
        let trimmed = untitled.replacingOccurrences(of: #"(?i)\s+(?:who|aged|age|is|was|works|working|from|in|at|based|the|a|an)\b.*$"#,
                                                  with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: ",;\n")).first ?? value
        let name = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' .?!"))
        let words = ResearchPlan.words(name)
        let nonNames: Set<String> = ["best", "local", "models", "model", "iphone", "weather", "climate", "change", "history", "information", "someone", "anyone", "person", "doctor", "doctors", "about", "latest", "news", "how", "why", "what", "research", "find"]
        guard (2...5).contains(words.count), !words.contains(where: { nonNames.contains($0) || Int($0) != nil }) else { return nil }
        return name
    }

    static func requestClues(_ request: String) -> [String] {
        let patterns = [
            #"(?i)\b(?:city|town|location|employer|organisation|organization|company)\s*[:=]\s*([^,;\n]+)"#,
            #"(?i)\b(?:in|from|at|based in|works at|working at)\s+([^,;\n]+?)(?=\s+(?:at|in|who|aged|age|works|working)\b|[,;\n]|$)"#
        ]
        var seen = Set<String>()
        var result: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let source = request as NSString
            for match in regex.matches(in: request, range: NSRange(location: 0, length: source.length)) {
                let clue = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if ResearchPlan.words(clue).count <= 8, seen.insert(ResearchPlan.normalized(clue)).inserted { result.append(clue) }
            }
        }
        return result
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
        return source.substring(with: match.range(at: 1))
    }
}
