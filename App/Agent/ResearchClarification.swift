import Foundation

/// User choices are based on attributable public claims, not model confidence.
struct ResearchClarification: Sendable {
    struct Choice: Sendable {
        let candidate: ResearchCandidate
        let details: [String]
        let fields: [String]
        var label: String { details.isEmpty ? candidate.title : details.joined(separator: " · ") }
    }
    let request: String
    let choices: [Choice]

    static func make(request: String, candidates: [ResearchCandidate], graph: ResearchGraph) -> Self? {
        let groups = Dictionary(grouping: graph.candidates, by: \.groupID)
        let supported = groups.values.filter { group in
            let sources = graph.sources.filter { source in
                source.duplicateOf == nil && group.contains { $0.sourceID == source.id && $0.anchors.count >= 2 }
            }
            return Set(sources.map(\.publisher)).count >= 2
        }
        guard supported.count != 1 || !graph.contradictions.isEmpty else { return nil }
        var choices: [Choice] = []
        var seen = Set<String>()
        for candidate in candidates {
            guard let source = graph.sources.first(where: { $0.url == candidate.url }), source.duplicateOf == nil,
                  let person = graph.candidates.first(where: { $0.sourceID == source.id }),
                  seen.insert(person.groupID).inserted else { continue }
            let claims = graph.claims.filter { $0.subjectID == person.entityID }
            guard !claims.isEmpty else { continue }
            let details = claims.filter { ["role", "organisation", "location"].contains($0.predicate) }
                .compactMap { claim in graph.entities.first(where: { $0.id == claim.objectID })?.label }
            let fields = claims.compactMap { claim -> String? in
                guard let value = graph.entities.first(where: { $0.id == claim.objectID })?.label else { return nil }
                switch claim.predicate {
                case "role": return "Job: " + value
                case "location": return "Location: " + value
                case "organisation": return "Employer: " + value
                default: return nil
                }
            }
            choices.append(Choice(candidate: candidate, details: Array(Set(details)).sorted(), fields: Array(Set(fields)).sorted()))
        }
        guard choices.count > 1 else { return nil }
        return Self(request: request, choices: Array(choices.prefix(6)))
    }

    var question: String {
        let options = choices.enumerated().map { "\($0.offset + 1). \($0.element.label)" }.joined(separator: "\n")
        return "I found separate profiles with this name. Which person do you mean? Choose a profile below, reply with its number, or tell me their job, city or organisation.\n\n" + options
    }

    func selection(for reply: String) -> ResearchCandidate? {
        let normalized = ResearchPlan.normalized(reply)
        let ordinal = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6]
        let number = Int(normalized) ?? ordinal[normalized]
        if let number, choices.indices.contains(number - 1) { return choices[number - 1].candidate }
        let matches = choices.filter { choice in
            choice.details.contains { detail in
                ResearchPlan.contains(detail, in: reply) || ResearchPlan.words(reply).contains {
                    ResearchPlanner.contextTerms.contains($0) && ResearchPlan.contains($0, in: detail)
                }
            }
        }
        return matches.count == 1 ? matches[0].candidate : nil
    }

    func request(for candidate: ResearchCandidate) -> String {
        let fields = choices.first(where: { $0.candidate.id == candidate.id })?.fields ?? []
        return request + (fields.isEmpty ? "" : "\n" + fields.joined(separator: "\n"))
    }

    func refinedRequest(with reply: String) -> String? {
        let words = ResearchPlan.words(reply)
        guard words.count <= 12,
              words.contains(where: { ResearchPlanner.contextTerms.contains($0) })
                || reply.range(of: #"(?i)\b(?:job|title|city|town|employer|organisation)\s*[:=]"#, options: .regularExpression) != nil
        else { return nil }
        return request + "\nAdditional detail: " + reply
    }
}
