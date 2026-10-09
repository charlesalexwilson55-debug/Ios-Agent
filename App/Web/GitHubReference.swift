import Foundation

enum GitHubReference {
    static func search(_ query: String, session: URLSession = .shared) async throws -> String {
        var components = URLComponents(string: "https://api.github.com/search/repositories")!
        components.queryItems = [URLQueryItem(name: "q", value: String(query.prefix(500))), URLQueryItem(name: "per_page", value: "6")]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("Conduit", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 || http.statusCode == 429 { throw ReferenceError.rateLimit }
            throw URLError(.badServerResponse)
        }
        struct Response: Decodable {
            struct Item: Decodable {
                let full_name: String
                let html_url: String
                let description: String?
                let stargazers_count: Int
            }
            let items: [Item]
        }
        let result = try JSONDecoder().decode(Response.self, from: data)
        return result.items.map { "\($0.full_name) | \($0.html_url) | \($0.stargazers_count) stars\n\($0.description ?? "")" }.joined(separator: "\n\n")
    }
    enum ReferenceError: LocalizedError {
        case rateLimit
        var errorDescription: String? { "GitHub's public API rate limit was reached. Use web_search with site:github.com instead." }
    }
}
