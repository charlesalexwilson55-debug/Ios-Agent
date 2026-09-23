import Foundation

// Keychain access is replaced with mutable placeholders so these tests never
// use a real credential or make a charged provider request.
enum SearchKeyStore {
    static var key: String?
    static var exaKey: String?
    static var hasResearchKey: Bool { key != nil || exaKey != nil }
}

final class ProviderFixtureProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let body: String
    }

    static var replies: [Reply] = []
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession commonly converts a POST's httpBody to an InputStream
        // before handing it to URLProtocol. Capture that body while it is live.
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            recorded.httpBody = data
        }
        Self.requests.append(recorded)
        let reply = Self.replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset(_ replies: [Reply]) {
        self.replies = replies
        requests = []
    }
}

@main struct ProviderTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        try await missingKeyDoesNotUseWikipedia(session)
        try await exaIsPrimaryDiscovery(session)
        try await tavilyAugmentsWithoutExtractingPages(session)
        try await tavilyFallbackReportsExaFailure(session)
        try await selectedPagesUseExaContents(session)
        try await selectedPagesFallbackToTavily(session)
        try await selectedPagesUseTavilyExtract(session)
        try await malformedResponsesAndCancellationPropagate(session)
        print("Provider boundary tests passed")
    }

    private static func missingKeyDoesNotUseWikipedia(_ session: URLSession) async throws {
        SearchKeyStore.exaKey = nil
        SearchKeyStore.key = nil
        ProviderFixtureProtocol.reset([])

        do {
            _ = try await WebSearch.research("source-grounded research", session: session)
            preconditionFailure("Research without either provider key must fail")
        } catch WebSearch.SearchError.researchNeedsKey {}

        precondition(ProviderFixtureProtocol.requests.isEmpty)
    }

    private static func exaIsPrimaryDiscovery(_ session: URLSession) async throws {
        SearchKeyStore.exaKey = "exa-test-placeholder"
        SearchKeyStore.key = nil
        ProviderFixtureProtocol.reset([
            .init(status: 200, body: #"{"results":[{"title":"Primary source","url":"https://example.com/source","publishedDate":"2026-09-20T00:00:00.000Z"}]}"#)
        ])

        let response = try await WebSearch.research("source-grounded research", session: session)
        precondition(response.provider == .exa)
        precondition(response.results.count == 1 && response.results[0].provider == .exa)
        precondition(response.results[0].published == "2026-09-20T00:00:00.000Z")
        precondition(ProviderFixtureProtocol.requests.count == 1)
        let request = ProviderFixtureProtocol.requests[0]
        precondition(request.url?.absoluteString == "https://api.exa.ai/search")
        precondition(request.value(forHTTPHeaderField: "x-api-key") == "exa-test-placeholder")
        let body = try requestBody(request)
        precondition(body["numResults"] as? Int == 8)
        precondition(body["contents"] == nil, "Discovery must not eagerly extract every result")
    }

    private static func tavilyAugmentsWithoutExtractingPages(_ session: URLSession) async throws {
        SearchKeyStore.exaKey = "exa-test-placeholder"
        SearchKeyStore.key = "tavily-test-placeholder"
        ProviderFixtureProtocol.reset([
            .init(status: 200, body: #"{"results":[{"title":"Exa result","url":"https://example.com/shared"},{"title":"Exa only","url":"https://exa.example/item"}]}"#),
            .init(status: 200, body: #"{"results":[{"title":"Duplicate","url":"https://example.com/shared","content":"duplicate"},{"title":"Tavily only","url":"https://tavily.example/item","content":"compact snippet"}]}"#)
        ])

        let response = try await WebSearch.research("broaden sources", session: session)
        precondition(response.provider == .combined)
        precondition(response.providers == [.exa, .tavily])
        precondition(response.results.map(\.url.absoluteString) == [
            "https://example.com/shared", "https://exa.example/item", "https://tavily.example/item"
        ])
        precondition(ProviderFixtureProtocol.requests.count == 2, "Research may make at most two provider calls")

        let tavilyRequest = ProviderFixtureProtocol.requests[1]
        precondition(tavilyRequest.url?.absoluteString == "https://api.tavily.com/search")
        let body = try requestBody(tavilyRequest)
        precondition(body["search_depth"] as? String == "basic")
        precondition(body["include_raw_content"] as? Bool == false)
    }

    private static func tavilyFallbackReportsExaFailure(_ session: URLSession) async throws {
        SearchKeyStore.exaKey = "exa-test-placeholder"
        SearchKeyStore.key = "tavily-test-placeholder"
        ProviderFixtureProtocol.reset([
            .init(status: 503, body: #"{"error":"overloaded"}"#),
            .init(status: 200, body: #"{"results":[{"title":"Fallback","url":"https://fallback.example/item","content":"result"}]}"#)
        ])

        let response = try await WebSearch.research("fallback", session: session)
        precondition(response.provider == .tavily)
        precondition(response.limitation?.contains("Exa") == true)
        precondition(response.limitation?.contains("503") == true)
        precondition(ProviderFixtureProtocol.requests.count == 2)
    }

    private static func selectedPagesUseExaContents(_ session: URLSession) async throws {
        SearchKeyStore.exaKey = "exa-test-placeholder"
        SearchKeyStore.key = "tavily-test-placeholder"
        ProviderFixtureProtocol.reset([
            .init(status: 200, body: #"{"results":[{"title":"Selected","url":"https://example.com/a","text":"Full selected page"}]}"#)
        ])

        let urls = [URL(string: "https://example.com/a")!]
        let results = try await WebSearch.extract(urls, session: session)
        precondition(results.count == 1 && results[0].rawContent == "Full selected page")
        precondition(results[0].provider == .exa)
        let request = ProviderFixtureProtocol.requests[0]
        precondition(request.url?.absoluteString == "https://api.exa.ai/contents")
        let body = try requestBody(request)
        precondition(body["urls"] as? [String] == ["https://example.com/a"])
        precondition(body["text"] as? Bool == true)
    }

    private static func selectedPagesUseTavilyExtract(_ session: URLSession) async throws {
        SearchKeyStore.exaKey = nil
        SearchKeyStore.key = "tavily-test-placeholder"
        ProviderFixtureProtocol.reset([
            .init(status: 200, body: #"{"results":[{"url":"https://example.com/a","raw_content":"Extracted page"}],"failed_results":[]}"#)
        ])

        let urls = [URL(string: "https://example.com/a")!]
        let results = try await WebSearch.extract(urls, session: session)
        precondition(results.count == 1 && results[0].rawContent == "Extracted page")
        precondition(results[0].provider == .tavily)
        let request = ProviderFixtureProtocol.requests[0]
        precondition(request.url?.absoluteString == "https://api.tavily.com/extract")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer tavily-test-placeholder")
        let body = try requestBody(request)
        precondition(body["urls"] as? [String] == ["https://example.com/a"])
        precondition(body["extract_depth"] as? String == "basic")
    }

    private static func selectedPagesFallbackToTavily(_ session: URLSession) async throws {
        SearchKeyStore.exaKey = "exa-test-placeholder"
        SearchKeyStore.key = "tavily-test-placeholder"
        ProviderFixtureProtocol.reset([
            .init(status: 503, body: #"{"error":"overloaded"}"#),
            .init(status: 200, body: #"{"results":[{"url":"https://example.com/a","raw_content":"Fallback page"}],"failed_results":[]}"#)
        ])

        let urls = [URL(string: "https://example.com/a")!]
        let results = try await WebSearch.extract(urls, session: session)
        precondition(results.count == 1 && results[0].rawContent == "Fallback page")
        precondition(results[0].provider == .tavily)
        precondition(results[0].limitation?.contains("Exa Contents") == true)
        precondition(results[0].limitation?.contains("HTTP 503") == true)
        precondition(ProviderFixtureProtocol.requests.map { $0.url?.host } == ["api.exa.ai", "api.tavily.com"])
    }

    private static func malformedResponsesAndCancellationPropagate(_ session: URLSession) async throws {
        SearchKeyStore.exaKey = "exa-test-placeholder"
        SearchKeyStore.key = nil
        ProviderFixtureProtocol.reset([.init(status: 200, body: #"{"unexpected":true}"#)])
        do {
            _ = try await WebSearch.research("malformed", session: session)
            preconditionFailure("Malformed provider data must not become no results")
        } catch WebSearch.SearchError.badResponse {}

        ProviderFixtureProtocol.reset([])
        let cancelled = Task {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await WebSearch.research("cancelled", session: session)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancellation must propagate")
        } catch is CancellationError {}
        precondition(ProviderFixtureProtocol.requests.isEmpty)
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        guard let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw WebSearch.SearchError.badResponse }
        return body
    }
}
