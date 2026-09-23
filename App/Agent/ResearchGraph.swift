import Foundation

/// Evidence is stored independently from the model. Scores below express rule
/// coverage, not calibrated probabilities or a claim of certain identity.
struct ResearchGraph: Codable, Sendable {
    struct Source: Codable, Identifiable, Sendable {
        let id: String
        let url: URL
        let title: String
        let text: String
        let published: String?
        let retrieved: Date
        let provider: String
        let publisher: String
        var duplicateOf: String?
    }
    struct Entity: Codable, Identifiable, Sendable {
        let id: String
        let label: String
        let kind: String
    }
    struct Evidence: Codable, Identifiable, Sendable {
        let id: String
        let sourceID: String
        let quote: String
        let retrieved: Date
        let published: String?
    }
    enum ClaimStatus: String, Codable, Sendable { case reported, corroborated, disputed }
    struct Claim: Codable, Identifiable, Sendable {
        let id: String
        let subjectID: String
        let predicate: String
        let objectID: String
        let text: String
        let period: String?
        var evidenceIDs: [String]
        var status: ClaimStatus = .reported
    }
    struct Candidate: Codable, Identifiable, Sendable {
        var id: String { sourceID }
        let sourceID: String
        let entityID: String
        var groupID: String
        var anchors: [String]
        var score: Int
        var reason: String
    }
    struct Contradiction: Codable, Identifiable, Sendable {
        let id: String
        let claimIDs: [String]
        let detail: String
    }
    struct Relationship: Codable, Identifiable, Sendable {
        let id: String
        let subjectID: String
        let predicate: String
        let objectID: String
        let claimID: String
    }
    var sources: [Source] = []
    var entities: [Entity] = []
    var evidence: [Evidence] = []
    var claims: [Claim] = []
    var candidates: [Candidate] = []
    var relationships: [Relationship] = []
    var contradictions: [Contradiction] = []

    mutating func addSource(url: URL, title: String, text: String, published: String?, provider: String) -> String? {
        guard let url = ResearchSourcePolicy.canonical(url), ResearchSourcePolicy.rejectReason(text) == nil else { return nil }
        if let existing = sources.first(where: { $0.url == url }) { return existing.id }
        let clean = ResearchSourcePolicy.publicText(text)
        guard clean.count >= 20 else { return nil }
        let duplicate = sources.first { ResearchSourcePolicy.similar($0.text, clean) }?.id
        let source = Source(id: UUID().uuidString, url: url, title: String(ResearchSourcePolicy.publicText(title).prefix(200)),
                            text: String(clean.prefix(8000)), published: published, retrieved: Date(), provider: provider,
                            publisher: ResearchSourcePolicy.publisher(url), duplicateOf: duplicate)
        sources.append(source)
        return source.id
    }

    /// Extracts only literal, attributable statements. A model-generated claim,
    /// date or relationship without its own source quotation cannot be stored.
    mutating func extract(_ output: String, sourceID: String, plan: ResearchPlan, selected: Bool) {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        struct Row: Decodable {
            let predicate: String
            let object: String
            let evidence_quote: String
            var period: String?
        }
        var rows: [Row] = []
        if let start = output.firstIndex(of: "["), let end = output.lastIndex(of: "]"), start <= end,
           let data = String(output[start...end]).data(using: .utf8),
           let parsed = try? JSONDecoder().decode([Row].self, from: data) { rows = Array(parsed.prefix(6)) }
        if rows.isEmpty, let regex = try? NSRegularExpression(pattern: #"\{[^{}]*\}"#) {
            let text = output as NSString
            // Preserve complete objects if a small model runs out of output
            // tokens before closing the array. Never repair invented field values.
            for match in regex.matches(in: output, range: NSRange(location: 0, length: text.length)).prefix(6) {
                if let data = text.substring(with: match.range).data(using: .utf8),
                   let row = try? JSONDecoder().decode(Row.self, from: data) { rows.append(row) }
            }
        }
        if rows.isEmpty {
            // Accept the previous app's concise format, but never its SAME vote.
            let quotes = selected ? plan.selectedStatements(source.text) : ResearchEngine.parse(output).evidence
            rows = quotes.flatMap { quote -> [Row] in
                let statements = selected ? [quote] : plan.attributedEvidence(quote, text: source.text)
                return statements.map { Row(predicate: "statement", object: $0, evidence_quote: $0) }
            }
        }
        let entityID = "person:" + sourceID
        let predicates: Set<String> = ["organisation", "location", "role", "education", "associated_with", "public_url", "statement"]
        for row in rows.prefix(6) {
            let quote = row.evidence_quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (15...900).contains(quote.count), predicates.contains(row.predicate),
                  ResearchPlan.contains(quote, in: source.text),
                  ResearchPlan.contains(row.object, in: quote),
                  !ResearchSourcePolicy.isSensitive(quote), ResearchSourcePolicy.rejectReason(quote) == nil else { continue }
            if row.predicate == "public_url" {
                guard let url = URL(string: row.object), ResearchSourcePolicy.canonical(url) != nil,
                      url.path.count > 2 else { continue }
            }
            // A quote must live within one subject's sentence/profile block.
            // In particular, don't lend a neighbouring person's employer to it.
            let attributed = plan.isTopic || plan.selectedStatements(quote).contains { $0 == quote }
                || plan.attributedEvidence(quote, text: source.text).contains { ResearchPlan.contains(row.object, in: $0) }
            guard attributed, plan.subject != nil || plan.isTopic || selected else { continue }
            if !entities.contains(where: { $0.id == entityID }) {
                entities.append(Entity(id: entityID, label: plan.subject ?? source.title, kind: plan.isTopic ? "topic" : "person"))
            }
            let objectLabel = String(row.object.prefix(900))
            let objectID = row.predicate + ":" + ResearchPlan.normalized(objectLabel)
            if !entities.contains(where: { $0.id == objectID }) {
                entities.append(Entity(id: objectID, label: objectLabel, kind: row.predicate))
            }
            let period = row.period.flatMap { ResearchPlan.contains($0, in: quote) ? $0 : nil }
            if claims.contains(where: { $0.subjectID == entityID && $0.predicate == row.predicate && $0.objectID == objectID && $0.period == period }) { continue }
            let ev = Evidence(id: UUID().uuidString, sourceID: sourceID, quote: quote, retrieved: source.retrieved, published: source.published)
            evidence.append(ev)
            let claim = Claim(id: UUID().uuidString, subjectID: entityID, predicate: row.predicate,
                              objectID: objectID, text: quote, period: period, evidenceIDs: [ev.id])
            claims.append(claim)
            if row.predicate != "statement" {
                relationships.append(Relationship(id: UUID().uuidString, subjectID: entityID, predicate: row.predicate, objectID: objectID, claimID: claim.id))
            }
        }
    }

    mutating func resolve(plan: ResearchPlan) {
        candidates = sources.map { source in
            let person = "person:" + source.id
            let quoted = claims.filter { $0.subjectID == person }.map(\.text).joined(separator: "\n")
            let anchors = plan.matchedClues(in: quoted)
            let score = (plan.hasSubject(in: quoted) && !quoted.isEmpty ? 20 : 0) + min(60, anchors.count * 25)
            return Candidate(sourceID: source.id, entityID: person, groupID: source.id, anchors: anchors, score: score,
                             reason: anchors.isEmpty ? "No distinguishing supplied details evidenced yet" : "Quoted evidence matches: " + anchors.joined(separator: ", "))
        }
        contradictions = []
        for i in claims.indices { claims[i].status = .reported }
        for i in candidates.indices {
            for j in candidates.indices where j > i {
                let a = claims.filter { $0.subjectID == candidates[i].entityID }
                let b = claims.filter { $0.subjectID == candidates[j].entityID }
                var conflict = false
                for first in a where ["organisation", "location", "role"].contains(first.predicate) {
                    for second in b where first.predicate == second.predicate && first.objectID != second.objectID {
                        // Historical differences need not conflict. Unknown periods stay unresolved.
                        if let p = first.period, let q = second.period, p != q { continue }
                        conflict = true
                        contradictions.append(Contradiction(id: first.id + ":" + second.id, claimIDs: [first.id, second.id],
                            detail: "Different stated \(first.predicate): may describe different people, multiple roles, or different dates. Keep separate until resolved."))
                    }
                }
                let shared = Set(candidates[i].anchors).intersection(candidates[j].anchors)
                // A website link alone is not ownership evidence: an employer
                // homepage or staff directory may be shared by many namesakes.
                guard !conflict, shared.count >= 2 else { continue }
                let firstGroup = candidates[i].groupID, secondGroup = candidates[j].groupID
                let firstPeople = Set(candidates.filter { $0.groupID == firstGroup }.map(\.entityID))
                let secondPeople = Set(candidates.filter { $0.groupID == secondGroup }.map(\.entityID))
                let groupA = claims.filter { firstPeople.contains($0.subjectID) }
                let groupB = claims.filter { secondPeople.contains($0.subjectID) }
                let groupConflict = groupA.contains { left in
                    ["organisation", "location", "role"].contains(left.predicate) && groupB.contains { right in
                        left.predicate == right.predicate && left.objectID != right.objectID
                            && (left.period == nil || right.period == nil || left.period == right.period)
                    }
                }
                guard !groupConflict else { continue }
                let old = candidates[j].groupID
                let target = candidates[i].groupID
                for k in candidates.indices where candidates[k].groupID == old { candidates[k].groupID = target }
            }
        }
        for i in claims.indices {
            guard let group = candidates.first(where: { $0.entityID == claims[i].subjectID })?.groupID else { continue }
            let matches = claims.filter { claim in
                claim.predicate == claims[i].predicate && claim.objectID == claims[i].objectID && claim.period == claims[i].period
                    && candidates.first(where: { $0.entityID == claim.subjectID })?.groupID == group
            }
            let ids = Set(matches.flatMap(\.evidenceIDs))
            let sourceIDs = Set(evidence.filter { ids.contains($0.id) }.map(\.sourceID))
            let independent = sources.filter { sourceIDs.contains($0.id) && $0.duplicateOf == nil }
            if Set(independent.map(\.publisher)).count >= 2 { claims[i].status = .corroborated }
        }
        // Even linked groups cannot turn source disagreement into a clean fact.
        let disputedIDs = Set(contradictions.flatMap(\.claimIDs))
        for i in claims.indices where disputedIDs.contains(claims[i].id) { claims[i].status = .disputed }
    }

    func gaps(plan: ResearchPlan) -> [ResearchQuery] {
        var queries: [ResearchQuery] = []
        for conflict in contradictions.prefix(2) {
            for claim in claims where conflict.claimIDs.contains(claim.id) {
                if let object = entities.first(where: { $0.id == claim.objectID }) {
                    queries.append(ResearchQuery(text: plan.anchor(object.label + " profile dates"), purpose: "Resolve differing \(claim.predicate)", evidenceIDs: claim.evidenceIDs))
                }
            }
        }
        for claim in claims where claim.status == .reported && claim.predicate != "statement" {
            guard let object = entities.first(where: { $0.id == claim.objectID }) else { continue }
            queries.append(ResearchQuery(text: plan.anchor(object.label), purpose: "Seek independent support for \(claim.predicate)", evidenceIDs: claim.evidenceIDs))
        }
        let seenClues = Set(candidates.flatMap(\.anchors))
        for clue in plan.clues where !seenClues.contains(clue) {
            queries.append(ResearchQuery(text: plan.anchor(clue + " professional profile"), purpose: "Check supplied detail: " + clue))
        }
        return queries
    }

    struct DisplayGroup: Identifiable {
        var id: String { sourceIDs[0] }
        var sourceIDs: [String]
        var attributes: [String]
        var name: String
    }

    /// Presentation groups require the same evidenced name and at least one
    /// common quoted attribute across EVERY member. No transitive identity merge.
    func displayGroups() -> [DisplayGroup] {
        var groups: [DisplayGroup] = []
        for candidate in candidates {
            let name = entities.first { $0.id == candidate.entityID }?.label ?? ""
            let attributes = Set(claims.filter {
                $0.subjectID == candidate.entityID && ["role", "organisation", "location", "education"].contains($0.predicate)
            }.map { $0.objectID })
            if !name.isEmpty, let index = groups.indices.first(where: {
                ResearchPlan.normalized(groups[$0].name) == ResearchPlan.normalized(name)
                    && !Set(groups[$0].attributes).isDisjoint(with: attributes)
            }) {
                groups[index].sourceIDs.append(candidate.sourceID)
                groups[index].attributes = Array(Set(groups[index].attributes).intersection(attributes)).sorted()
            } else {
                groups.append(.init(sourceIDs: [candidate.sourceID], attributes: attributes.sorted(), name: name))
            }
        }
        return groups.map { group in
            var result = group
            result.attributes = group.sourceIDs.count > 1 ? group.attributes.map { id in
                let label = entities.first { $0.id == id }?.label ?? id
                return "\(id.components(separatedBy: ":")[0]): \(label)"
            } : []
            return result
        }
    }

    func report() -> String {
        var paragraphs: [String] = []
        for group in displayGroups() {
            if group.sourceIDs.count > 1 {
                paragraphs.append("**Sources sharing \(group.name) and \(group.attributes.joined(separator: ", "))**\n\nShared details organise these sources; they do not prove the profiles are the same person.")
            }
            for candidate in candidates.filter({ group.sourceIDs.contains($0.sourceID) }) {
            guard let source = sources.first(where: { $0.id == candidate.sourceID }) else { continue }
            let items = claims.filter { $0.subjectID == candidate.entityID }
            guard !items.isEmpty else { continue }
            paragraphs.append("**[\(source.title)](\(source.url.absoluteString))** — \(candidate.reason). Identity remains provisional.")
            for claim in items {
                let label = claim.status == .corroborated ? "Corroborated across distinct, nonduplicate sites" : claim.status == .disputed ? "Unresolved difference" : "Reported by this source"
                paragraphs.append("- \(claim.text) — *\(label)* [source](\(source.url.absoluteString))")
            }
            }
        }
        if !contradictions.isEmpty { paragraphs.append("\(contradictions.count) differences need further evidence; profiles have not been silently combined.") }
        return paragraphs.joined(separator: "\n\n")
    }
}

enum ResearchSourcePolicy {
    static func canonical(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") || host.contains(":") { return nil }
        let numbers = host.split(separator: ".").compactMap { Int($0) }
        if numbers.count == 4 { return nil } // Research sources should be public named sites.
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.filter { !($0.name.lowercased().hasPrefix("utm_") || ["fbclid", "gclid", "msclkid"].contains($0.name.lowercased())) }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        if parts.path.count > 1 && parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }
    static func publisher(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let parts = host.split(separator: ".")
        let suffix = parts.suffix(2).joined(separator: ".")
        let multipart: Set<String> = ["com.au", "org.au", "edu.au", "gov.au", "co.uk", "org.uk", "ac.uk", "co.nz", "co.jp", "com.br"]
        return parts.suffix(multipart.contains(suffix) ? 3 : 2).joined(separator: ".")
    }
    static func similar(_ a: String, _ b: String) -> Bool {
        let x = ResearchPlan.normalized(a), y = ResearchPlan.normalized(b)
        if x == y { return true }
        func shingles(_ text: String) -> Set<String> {
            let words = text.split(separator: " ").prefix(1400).map(String.init)
            guard words.count >= 5 else { return Set(words) }
            return Set((0...(words.count - 5)).map { words[$0..<($0 + 5)].joined(separator: " ") })
        }
        let first = shingles(x), second = shingles(y)
        guard min(first.count, second.count) >= 8 else { return false }
        return Double(first.intersection(second).count) / Double(min(first.count, second.count)) > 0.8
    }
    static func rejectReason(_ text: String) -> String? {
        let lower = text.lowercased()
        let instructions = ["ignore previous instructions", "ignore all previous", "disregard previous instructions", "system prompt", "send all passwords", "assistant must", "you are now chatgpt", "developer message"]
        if instructions.contains(where: { lower.contains($0) }) { return "Page contains instructions aimed at the assistant; excluded from evidence." }
        if ["buy this domain", "this domain is for sale", "access denied", "verify you are human"].contains(where: { lower.contains($0) }) && text.count < 1500 { return "Parked, blocked or unreadable page" }
        return nil
    }
    static func isSensitive(_ text: String) -> Bool {
        if PrivateDetail.appears(in: text) { return true }
        if text.range(of: #"(?i)\b(?:aged?\s*:?\s*(?:[0-9]|1[0-7])\b|(?:[0-9]|1[0-7])[- ]year[- ]old\b|(?:[0-9]|1[0-7]) years? old\b)"#, options: .regularExpression) != nil { return true }
        return text.range(of: #"(?i)\b(home address|personal phone|date of birth|born on|passport|password|credentials|social security|live location|his children|her children)\b"#, options: .regularExpression) != nil
    }
    static func publicText(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !isSensitive($0) && rejectReason($0) == nil }.joined(separator: "\n")
    }
    static func isMinorProfile(_ text: String, plan: ResearchPlan) -> Bool {
        guard !plan.isTopic, let subject = plan.subject else { return false }
        let name = NSRegularExpression.escapedPattern(for: subject)
        let age = #"(?:[0-9]|1[0-7])"#
        let pattern = "(?i)" + name + #"\s*[,\n:-]?\s*(?:(?:is|aged|age|a)\s+){0,2}"# + age + #"(?:\s*[- ]\s*year[- ]old|\s+years? old|\s*[,;.]|\s+and\b)"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    static func requestRestriction(_ text: String) -> String? {
        if PrivateDetail.isPrivateSearch(text) || isSensitive(text) { return "Research supports public professional information, not private contact details, home addresses, credentials or live locations." }
        if text.range(of: #"(?i)\b(?:age[d]?\s*:?\s*|)(?:[0-9]|1[0-7])\s*(?:years? old|year[- ]old)\b|\baged?\s*:?\s*(?:[0-9]|1[0-7])\b|\b(?:minor|child|schoolgirl|schoolboy)\b"#, options: .regularExpression) != nil {
            return "Research cannot build personal profiles of minors. You can research an organisation or public topic instead."
        }
        return nil
    }
}
