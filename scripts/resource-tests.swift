import Foundation

final class GitHubFixture: URLProtocol {
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"items":[{"full_name":"owner/docs","html_url":"https://github.com/owner/docs","description":"Reference documentation","stargazers_count":10}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ResourceTests {
    static func main() async throws {
        precondition(TaskRouter.mode(for: "Reply with hello.", previousTurnUsedPhoneTools: false) == .answer,
            "A literal chat reply must not expose every phone tool")
        precondition(TaskRouter.mode(for: "Reply to Sam with hello", previousTurnUsedPhoneTools: false) == .task)
        let names = ["search_libraries", "read_library_photo", "create_files", "github_search", "web_search", "read_page", "send_message"]
        let tools = names.map { ToolDescriptor(name: $0, description: "Fixture", params: [], friction: .silent, category: "test") }
        let online = Set(TaskRouter.tools(from: tools, mode: .answer, online: true).map(\.name))
        precondition(online.contains("search_libraries") && online.contains("read_library_photo") && online.contains("create_files"))
        precondition(online.contains("github_search") && !online.contains("send_message"))
        let offline = Set(TaskRouter.tools(from: tools, mode: .answer, online: false).map(\.name))
        precondition(offline.contains("search_libraries") && !offline.contains("github_search") && !offline.contains("read_page"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubFixture.self]
        let session = URLSession(configuration: configuration)
        let result = try await GitHubReference.search("docs", session: session)
        precondition(result.contains("owner/docs") && result.contains("Reference documentation"))
        GitHubFixture.status = 403
        do { _ = try await GitHubReference.search("docs", session: session); fatalError("Rate limit was hidden") }
        catch GitHubReference.ReferenceError.rateLimit {}
        print("Library/creation access, offline web gating and GitHub retrieval/rate-limit tests passed")
    }
}
