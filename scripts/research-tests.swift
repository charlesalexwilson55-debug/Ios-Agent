import Foundation

// Platform-only dependencies are replaced; the real research engine, provider,
// ranking and evidence rules are compiled and exercised below on macOS CI.
enum SearchKeyStore {
    static var key: String? = "test-placeholder"
    static var hasKey: Bool { key != nil }
}
@MainActor enum PageReader {
    struct Page { let text: String }
    static func read(_ url: URL) async throws -> Page { throw URLError(.cannotLoadFromNetwork) }
}
final class SearchFixtureProtocol: URLProtocol {
    static var status = 200
    static var payload = "{\"results\":[]}"
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ResearchTests {
    @MainActor static func main() async throws {
        let request = "Research Jane Example, doctor in Melbourne at Harbour Clinic"
        let plan = ResearchPlan(request: request, subject: "Jane Example",
                                keywords: ["Jane Example", "doctor", "Melbourne", "Harbour Clinic"], identityClues: ["Melbourne", "Harbour Clinic"])
        let queries = plan.queries
        precondition(queries.allSatisfy { $0.contains("\"Jane Example\"") }, "Every person search must keep the full name")
        precondition(queries.contains { $0.contains("hospital") || $0.contains("clinic") }, "Search relevant professional sources")
        precondition(!queries.contains("doctor"), "Do not search unrelated keywords alone")
        precondition(!plan.hasSubject(in: "Jane Examples is a doctor"), "Name boundary must match")
        precondition(plan.hasSubject(in: "Dr Jane A. Example, Melbourne"), "Allow a middle initial")
        precondition(!plan.accepts(evidence: ["Jane Example is a doctor in Melbourne."], text: "John Example is a doctor in Melbourne."), "Invented evidence must fail")
        precondition(!plan.accepts(evidence: ["Jane Example is a doctor."], text: "Jane Example is a doctor."), "A common profession alone must not establish identity")
        precondition(plan.accepts(evidence: ["Jane Example is a doctor at Harbour Clinic in Melbourne."], text: "Jane Example is a doctor at Harbour Clinic in Melbourne."), "Name and disambiguating clues should pass")
        let professionOnly = ResearchPlan(request: "Jane Example scientist", subject: "Jane Example", keywords: ["Jane Example", "scientist"])
        precondition(!professionOnly.accepts(evidence: ["Jane Example is a scientist."], text: "Jane Example is a scientist."))
        let twoPeople = "Jane Example works in Sydney. John Other works in Melbourne."
        precondition(!plan.accepts(evidence: [twoPeople], text: twoPeople), "Do not borrow another person's city")
        let joinedPeople = "Jane Example works in Sydney and John Other works in Melbourne."
        precondition(!plan.accepts(evidence: [joinedPeople], text: joinedPeople), "Do not borrow a city across joined statements")
        let mixedQuote = "Jane Example works at Harbour Clinic. John Other won the surgical award."
        precondition(plan.attributedEvidence(mixedQuote, text: mixedQuote) == ["Jane Example works at Harbour Clinic."], "Only retain the subject's own statement")
        precondition(plan.score(title: "Website builder", summary: "Make a website with Wix", url: URL(string: "https://wix.com/")!) < 0)
        precondition(plan.score(title: "Jane Example — doctor", summary: "Harbour Clinic Melbourne", url: URL(string: "https://harbour-clinic.example/team/jane")!) > 0)
        precondition(plan.score(title: "Jane Example", summary: "Doctor at Harbour Clinic Melbourne", url: URL(string: "https://jane-clinic.wixsite.com/home")!) > 0, "Do not ban real practices hosted by Wix")
        let invalid = ResearchPlan(request: request, subject: "John Invented", keywords: ["doctor"])
        precondition(invalid.subject == nil, "Never invent the subject")
        precondition(plan.excerpt(String(repeating: "Navigation menu ", count: 700) + "Jane Example is a doctor at Harbour Clinic in Melbourne.", limit: 300).contains("Harbour Clinic"), "Read the relevant passage, not just the page beginning")
        print("Research policy regression tests passed")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        SearchKeyStore.key = nil
        do {
            _ = try await WebSearch.research("Jane Example", session: session)
            preconditionFailure("Missing key must not fall back to Wikipedia")
        } catch WebSearch.SearchError.researchNeedsKey {}
        precondition(SearchFixtureProtocol.requests.isEmpty)
        SearchKeyStore.key = "test-placeholder"
        SearchFixtureProtocol.status = 401
        do {
            _ = try await WebSearch.research("Jane Example", session: session)
            preconditionFailure("Rejected key must not become a no-results answer")
        } catch WebSearch.SearchError.http(401) {}
        precondition(SearchFixtureProtocol.requests.count == 1)
        precondition(SearchFixtureProtocol.requests.allSatisfy { $0.url?.host == "api.tavily.com" })
        SearchFixtureProtocol.status = 200
        SearchFixtureProtocol.payload = "{\"unexpected\":true}"
        do {
            _ = try await WebSearch.research("Jane Example", session: session)
            preconditionFailure("Malformed provider response must not become zero results")
        } catch WebSearch.SearchError.badResponse {}
        SearchFixtureProtocol.payload = "{\"results\":[]}"
        let empty = try await WebSearch.research("Jane Example", session: session)
        precondition(empty.results.isEmpty)
        print("Search provider failure regression tests passed")

        let variants = [
            "",
            "I will search for Jane Example, a doctor in Melbourne at Harbour Clinic.",
            "```json\n{\"name\":\"Jane Example\",\"city\":\"Melbourne\",\"employer\":\"Harbour Clinic\"}\n```",
            "1. **Full name:** Jane Example\n- City: Melbourne\n- Employer = Harbour Clinic",
            "NAME: John Invented\nLOCATION: Wrongtown",
            "NAME: none"
        ]
        for output in variants {
            let recovered = ResearchPlanner.make(request: request, reply: output)
            precondition(recovered.subject == "Jane Example", "Recover name from supplied request: \(output)")
            precondition(recovered.clues.contains("Melbourne") && recovered.clues.contains("Harbour Clinic"))
            precondition(recovered.queries.allSatisfy { $0.contains("\"Jane Example\"") })
            precondition(!recovered.queries.contains { $0.contains("Invented") || $0.contains("Wrongtown") })
        }
        let lowercase = ResearchPlanner.make(request: "find jane example, a doctor in melbourne at harbour clinic", reply: "")
        precondition(lowercase.subject == "jane example")
        let lowerNone = ResearchPlanner.make(request: "research jane example in melbourne", reply: "NAME: none")
        precondition(lowerNone.subject == "jane example" && !lowerNone.isTopic)
        precondition(!lowerNone.accepts(evidence: ["John Other works in Melbourne."], text: "John Other works in Melbourne."))
        let titled = ResearchPlanner.make(request: "Research Dr. Jane Example in Melbourne", reply: "NAME: Dr. Jane Example\nLOCATION: Melbourne")
        precondition(titled.subject == "Jane Example", "Honorifics are not required parts of a person's name")
        let unresolvedRequest = "Find information about the person I described earlier"
        let unresolved = ResearchPlanner.make(request: unresolvedRequest, reply: "not structured")
        precondition(unresolved.subject == nil && unresolved.queries == [unresolvedRequest])
        precondition(!unresolved.accepts(evidence: ["John Other works in Melbourne."], text: "John Other works in Melbourne."))
        let topic = ResearchPlanner.make(request: "research the best local AI models for iPhone", reply: "NAME: none\nKEYWORD: models")
        precondition(topic.isTopic && topic.subject == nil)
        precondition(topic.accepts(evidence: ["The model uses four-bit weights."], text: "The model uses four-bit weights."), "Explicit topic research must still produce source evidence")
        print("Research planning recovery regression tests passed")

        let profile = "  **NAME:** Jane Example\nLOCATION: Melbourne\nORGANISATION: Harbour Clinic\nKEYWORD: Jane Example\nKEYWORD: doctor\nKEYWORD: Melbourne\nKEYWORD: Harbour Clinic"
        let sentence = "Jane Example is a doctor at Harbour Clinic in Melbourne."
        let source = WebSearch.Result(title: "Jane Example doctor", url: URL(string: "https://harbour-clinic.example/team/jane")!, site: "harbour-clinic.example", summary: sentence, published: nil, rawContent: sentence + String(repeating: " Practice information.", count: 15))
        var log = ActivityLog(title: "Test research")
        let reporter = ActivityReporter { edit in edit(&log) }
        let engine = ResearchEngine(request: request, budget: .normal, ask: { system, _ in
            if system == ResearchEngine.keywordPrompt { return profile }
            if system == ResearchEngine.crossCheckPrompt { return "NONE" }
            return "SAME: yes\nEVIDENCE: \(sentence)\nCONTRADICTION: NONE"
        }, activity: reporter, search: { query in
            precondition(query.contains("\"Jane Example\""))
            return WebSearch.Response(provider: .tavily, results: [source])
        })
        let findings = try await engine.run()
        precondition(findings.pagesMatched == 1, "Duplicate URLs must be read only once")
        precondition(findings.facts.count == 1 && findings.facts[0].url == source.url)
        precondition(findings.identitySummary.contains("provisional"))
        let invented = ResearchEngine(request: request, budget: .normal, ask: { system, _ in
            system == ResearchEngine.keywordPrompt ? profile : "SAME: yes\nEVIDENCE: Jane Example works in Sydney at Imaginary Clinic."
        }, activity: reporter, search: { _ in WebSearch.Response(provider: .tavily, results: [source]) })
        let rejected = try await invented.run()
        precondition(rejected.facts.isEmpty, "A model's yes cannot override absent evidence")
        let teamText = "Jane Example works at Harbour Clinic. John Other won the surgical award."
        let team = WebSearch.Result(title: "Jane Example doctor", url: source.url, site: source.site, summary: "Harbour Clinic", published: nil, rawContent: teamText + String(repeating: " Team information.", count: 15))
        let mixed = ResearchEngine(request: request, budget: .normal, ask: { system, _ in
            system == ResearchEngine.keywordPrompt ? profile : "SAME: yes\nEVIDENCE: Jane Example works at Harbour Clinic.\nEVIDENCE: John Other won the surgical award.\nEVIDENCE: Jane Example lives in Melbourne."
        }, activity: reporter, search: { _ in WebSearch.Response(provider: .tavily, results: [team]) })
        let attributed = try await mixed.run()
        precondition(attributed.facts.count == 1 && !attributed.facts[0].text.contains("John Other"))
        precondition(attributed.identitySummary.contains("Unverified supplied clues: Melbourne"), "Invented quotes cannot confirm missing clues")
        let noName = ResearchEngine(request: request, budget: .normal, ask: { _, _ in "KEYWORD: doctor" }, activity: reporter, search: { query in
            precondition(query.contains("\"Jane Example\""), "Fallback searches must preserve the name")
            return WebSearch.Response(provider: .tavily, results: [source])
        })
        let recovered = try await noName.run()
        precondition(recovered.searches > 0 && recovered.facts.isEmpty)
        precondition(recovered.candidates.count == 1 && recovered.candidates[0].status == .possible, "Uncertain source must remain selectable")
        let modelFailure = ResearchEngine(request: request, budget: .normal, ask: { _, _ in throw URLError(.cannotDecodeContentData) }, activity: reporter, search: { _ in WebSearch.Response(provider: .tavily, results: [source]) })
        let modelFailed = try await modelFailure.run()
        precondition(!modelFailed.candidates.isEmpty && modelFailed.searches > 0, "Model failure must not prevent source discovery")
        let cancelled = Task { @MainActor in
            let cancelledEngine = ResearchEngine(request: request, budget: .normal, ask: { _, _ in
                try Task.checkCancellation()
                return ""
            }, activity: reporter, search: { _ in preconditionFailure("A cancelled run must not start searches") })
            return try await cancelledEngine.run()
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancellation must still propagate") }
        catch is CancellationError {}
        let selected = ResearchEngine(request: request, budget: .normal, ask: { _, _ in "" }, activity: reporter, search: { _ in WebSearch.Response(provider: .tavily, results: [team]) }, selection: recovered.candidates[0], read: { _ in sentence })
        let focused = try await selected.run()
        precondition(focused.facts.count == 1 && focused.facts[0].url == source.url)
        precondition(focused.identitySummary.contains("not a verified identity match"))
        let otherSource = WebSearch.Result(title: "Jane Example doctor", url: URL(string: "https://different-clinic.example/jane")!, site: "different-clinic.example", summary: "Jane Example in Melbourne", published: nil, rawContent: "Jane Example is a doctor in Melbourne at Different Clinic." + String(repeating: " Clinic info.", count: 20))
        let selectionWithOther = ResearchEngine(request: request, budget: .normal, ask: { _, _ in "" }, activity: reporter, search: { _ in WebSearch.Response(provider: .tavily, results: [otherSource]) }, selection: recovered.candidates[0], read: { _ in sentence })
        let separated = try await selectionWithOther.run()
        precondition(separated.facts.allSatisfy { $0.url == source.url }, "Selection must not merge a different same-name profile")
        precondition(separated.candidates.contains { $0.url == otherSource.url && $0.status == .possible })
        let bio = "Jane Example\nShe works at Harbour Clinic in Melbourne.\nJohn Other\nHe won an award."
        let profileStatements = plan.selectedStatements(bio)
        precondition(profileStatements.count == 1 && profileStatements[0].contains("She works"))
        precondition(!profileStatements[0].contains("John Other"))
        let cached = ResearchCandidate(title: source.title, url: source.url, snippet: "", status: .possible, reason: "", matchedClues: [], sourceText: bio)
        let cachedEngine = ResearchEngine(request: request, budget: .normal, ask: { _, _ in "" }, activity: reporter, search: { _ in WebSearch.Response(provider: .tavily, results: []) }, selection: cached, read: { _ in preconditionFailure("Cached provider text should survive a failed direct reader") })
        let cachedFindings = try await cachedEngine.run()
        precondition(cachedFindings.facts.count == 1 && cachedFindings.facts[0].text.contains("She works"))
        let several = ResearchCandidate(title: source.title, url: source.url, snippet: "", status: .possible, reason: "", matchedClues: [], sourceText: "Jane Example works at Harbour Clinic. Jane Example teaches in Melbourne. Jane Example studies clinical medicine.")
        let brokenCrosscheck = ResearchEngine(request: request, budget: .normal, ask: { _, _ in throw URLError(.cannotDecodeContentData) }, activity: reporter, search: { _ in WebSearch.Response(provider: .tavily, results: []) }, selection: several)
        let retained = try await brokenCrosscheck.run()
        precondition(retained.facts.count == 3 && retained.limitations.contains { $0.contains("cross-checking") })
        let unavailable = ResearchEngine(request: request, budget: .normal, ask: { _, _ in profile }, activity: reporter, search: { _ in throw WebSearch.SearchError.http(429) })
        let failed = try await unavailable.run()
        precondition(!failed.limitations.isEmpty && failed.facts.isEmpty, "Retain provider failure, not person-not-found")
        print("Research engine fixture regression tests passed")
    }
}
