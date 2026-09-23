import Foundation

/// Deterministic query and evidence rules surrounding the small local model.
/// Matching is deliberately conservative: a name or a common occupation alone
/// is a lead, not proof that two profiles describe the same person.
struct ResearchPlan: Codable, Sendable {
    let subject: String?
    let keywords: [String]
    let request: String
    let isTopic: Bool
    private let identityClues: [String]

    init(request: String, subject: String?, keywords: [String], identityClues: [String] = [], isTopic: Bool = false) {
        self.request = request
        self.isTopic = isTopic
        let candidate = subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.subject = Self.words(candidate).count >= 2 && Self.contains(candidate, in: request)
            ? candidate : nil
        self.keywords = keywords.filter { Self.contains($0, in: request) }
        self.identityClues = identityClues.filter { Self.contains($0, in: request) }
    }

    private static let medical = ["doctor", "physician", "surgeon", "gp", "dentist", "cardiologist", "psychiatrist"]
    private static let roles = Set(medical + ["dr", "professor", "researcher", "scientist", "lawyer", "solicitor", "architect", "engineer", "software", "teacher", "author", "nurse", "a", "an", "the"])
    private var isMedical: Bool { Self.words(request).contains { Self.medical.contains($0) } }

    var clues: [String] {
        identityClues.filter { key in
            key != subject && !Self.words(key).allSatisfy { Self.roles.contains($0) || Int($0) != nil }
                && !(subject.map { Self.contains(key, in: $0) } ?? false)
        }
    }

    var queries: [String] {
        // A failed extraction must not drop the name, age or context the user
        // already supplied. Search their wording and keep results as candidates.
        guard let subject else { return [request] }
        let name = "\"\(subject)\""
        let context = keywords.filter { !Self.contains($0, in: subject) }.joined(separator: " ")
        var result = ["\(name) \(request)", "\(name) \(context)"]
        if isMedical {
            // Profession terms guide discovery without guessing the person's country
            // or excluding small practices on ordinary commercial domains.
            result += ["\(name) doctor hospital clinic \(clues.joined(separator: " "))",
                       "\(name) medical practitioner register",
                       "\(name) hospital staff profile"]
        } else if Self.words(request).contains(where: { ["professor", "researcher", "scientist"].contains($0) }) {
            result += ["\(name) university faculty profile", "\(name) publications ORCID"]
        } else {
            result.append("\(name) professional profile \(context)")
        }
        // Always keep the subject; dropping clues is useful, dropping the name isn't.
        for clue in clues { result.append("\(name) \(clue)") }
        result.append(name)
        var seen = Set<String>()
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { seen.insert(Self.normalized($0)).inserted }
    }

    func anchor(_ query: String) -> String {
        guard let subject, !Self.contains(subject, in: query) else { return query }
        return "\"\(subject)\" \(query)"
    }

    func hasSubject(in text: String) -> Bool {
        guard let subject else { return true }
        if Self.contains(subject, in: text) { return true }
        let name = Self.words(subject)
        let tokens = Self.words(text)
        // Permit a middle name/initial, but not arbitrary distant co-occurrences.
        guard name.count == 2, tokens.count >= 3 else { return false }
        return tokens.indices.contains { index in
            tokens[index] == name[0] && index + 2 < tokens.count && tokens[index + 2] == name[1]
        }
    }

    func matchedClues(in text: String) -> [String] {
        clues.filter { Self.contains($0, in: text) }
    }

    func accepts(evidence: [String], text: String) -> Bool {
        evidence.contains { !attributedEvidence($0, text: text).isEmpty }
    }

    /// Never attach a neighbouring person's sentence to a valid identity quote.
    /// Each retained statement must itself link the name and distinguishing clue.
    func attributedEvidence(_ quote: String, text: String) -> [String] {
        guard quote.count >= 15, Self.contains(quote, in: text) else { return [] }
        guard subject != nil else { return isTopic ? [quote] : [] }
        let separated = quote.replacingOccurrences(
            of: #"(?<=[.!?;])\s+|\n+|\s+(?:while|whereas|but|and)\s+"#,
            with: "\n", options: [.regularExpression, .caseInsensitive])
        return separated.components(separatedBy: .newlines).filter {
            hasSubject(in: $0) && !matchedClues(in: $0).isEmpty
        }
    }

    /// A user-selected page can be described without asserting it belongs to
    /// the requested person. Retain short literal statements, never model guesses.
    func selectedStatements(_ text: String) -> [String] {
        let separated = text.replacingOccurrences(
            of: #"(?<=[.!?;])\s+|\n+|\s+(?:while|whereas|but|and)\s+"#,
            with: "\n", options: [.regularExpression, .caseInsensitive])
        var statements = Array(separated.components(separatedBy: .newlines).filter {
            $0.count >= 20 && $0.count <= 600 && (subject == nil || hasSubject(in: $0))
        }.prefix(4))
        // Many profiles place the name in a heading and use "she/he/they" in
        // the bio. Keep the heading with its immediate paragraph, stopping at
        // another heading rather than collecting a neighbouring person's bio.
        if subject != nil, statements.isEmpty {
            let lines = text.components(separatedBy: .newlines)
            if let heading = lines.firstIndex(where: { $0.count <= 120 && hasSubject(in: $0) }) {
                var context = [lines[heading]]
                for line in lines.dropFirst(heading + 1).prefix(5) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }
                    let tokens = trimmed.split(separator: " ")
                    let otherHeading = (2...5).contains(tokens.count)
                        && tokens.allSatisfy { $0.first?.isUppercase == true }
                        && !hasSubject(in: trimmed) && matchedClues(in: trimmed).isEmpty
                    if trimmed.hasPrefix("#") || otherHeading { break }
                    context.append(line)
                    if trimmed.count >= 20 { break }
                }
                let excerpt = context.joined(separator: "\n")
                if context.count > 1, excerpt.count <= 800 { statements.append(excerpt) }
            }
        }
        return statements
    }

    func score(title: String, summary: String, url: URL) -> Int {
        let text = title + " " + summary
        let normalized = Self.normalized(text)
        let host = url.host?.lowercased() ?? ""
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), !host.isEmpty else { return -100 }
        if ["domain.com", "wix.com", "godaddy.com", "squarespace.com"].contains(host.replacingOccurrences(of: "www.", with: "")) && !hasSubject(in: text) { return -100 }
        if ["domain for sale", "buy this domain", "parked domain", "website builder", "access denied", "just a moment"].contains(where: { normalized.contains($0) }) && !hasSubject(in: text) { return -100 }
        // Keep an official directory as a lower-priority lead when its snippet
        // omits the name, but reject partial-name attractions and unrelated pages.
        if subject != nil && !hasSubject(in: text) {
            let directory = ["staff", "team", "directory", "practitioners", "faculty", "register"].contains { normalized.contains($0) }
            return directory && !matchedClues(in: text).isEmpty ? 0 : -100
        }
        var score = subject == nil ? 0 : (hasSubject(in: text) ? 20 : -5)
        score += matchedClues(in: text).count * 5
        if isMedical && ["hospital", "clinic", "practitioner", "physician", "surgeon", "medical"].contains(where: { normalized.contains($0) }) { score += 8 }
        if host.hasSuffix(".gov") || host.contains(".gov.") || host.hasSuffix(".edu") || host.contains(".edu.") { score += 3 }
        return score
    }

    /// Keep context around name occurrences. Important bios are often below menus.
    func excerpt(_ text: String, limit: Int) -> String {
        guard text.count > limit, let subject else { return String(text.prefix(limit)) }
        let tokens = Self.words(subject)
        let needle = text.range(of: subject, options: [.caseInsensitive, .diacriticInsensitive])
            ?? tokens.last.flatMap { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
        guard let needle else { return String(text.prefix(limit)) }
        let start = text.index(needle.lowerBound, offsetBy: -min(300, limit / 4), limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start...].prefix(limit))
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    static func normalized(_ text: String) -> String { words(text).joined(separator: " ") }
    static func contains(_ phrase: String, in text: String) -> Bool {
        let phrase = normalized(phrase)
        return !phrase.isEmpty && (" " + normalized(text) + " ").contains(" " + phrase + " ")
    }
}
