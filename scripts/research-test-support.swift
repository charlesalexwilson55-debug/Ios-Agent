import Foundation

// Platform-only dependencies are replaced; the real research engine, provider,
// ranking and evidence rules are compiled and exercised below on macOS CI.
enum SearchKeyStore {
    static var key: String? = "test-placeholder"
    static var hasKey: Bool { key != nil }
    static var tavilyKey: String? { key }
    static var hasExaKey: Bool { exaKey != nil }
    static var hasTavilyKey: Bool { key != nil }
    static var exaKey: String? = nil
    static var hasResearchKey: Bool { key != nil || exaKey != nil }
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

