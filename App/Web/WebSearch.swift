import Foundation

/// Web search for the model.
///
/// Tavily when the user has added a key: an API built for AI assistants,
/// with 1,000 free searches a month and no card needed. Otherwise
/// Wikipedia's official API, which needs no key. DuckDuckGo's HTML page was
/// tried and rejected: it blocks a client after a single automated query.
enum WebSearch {

    enum Provider: String {
        case tavily, wikipedia
    }

    struct Result: Sendable {
        let title: String
        let url: URL
        let site: String
        let summary: String
        let published: String?
        var rawContent: String? = nil
    }

    struct Response: Sendable {
        let provider: Provider
        let results: [Result]
        var answer: String?
        var limitation: String?
    }

    enum SearchError: LocalizedError {
        case http(Int)
        case badResponse
        case researchNeedsKey

        var errorDescription: String? {
            switch self {
            case .researchNeedsKey: "Research needs a working full-web search key. Add your Tavily key in Sidebar → Online. Wikipedia alone cannot perform this research."
            case .http(401): "The web search key was rejected. Replace it in Sidebar → Online."
            case .http(429), .http(432), .http(433): "The web search provider's rate or usage limit was reached. Research stopped; this does not mean the person was not found."
            case .http(let status): "the search service answered with error \(status)."
            case .badResponse: "the search service sent something unreadable."
            }
        }
    }

    static let noKeyLimitation = "No web search key is set, so only Wikipedia was searched. "
        + "For news, prices or local information, tell the user that a free Tavily key can be "
        + "added on the Online page."

    private static let userAgent = "Conduit/1.0 (personal on-device assistant for iOS)"
    private static let summaryLimit = 320

    static func search(_ query: String) async throws -> Response {
        guard let key = SearchKeyStore.key else {
            var response = try await wikipedia(query)
            response.limitation = noKeyLimitation
            return response
        }
        do {
            return try await tavily(query, key: key)
        } catch {
            try Task.checkCancellation()
            var response = try await wikipedia(query)
            response.limitation = tavilyProblem(error)
            return response
        }
    }

    /// Research must never silently degrade into an encyclopedia-only search.
    static func research(_ query: String, session: URLSession = .shared) async throws -> Response {
        try Task.checkCancellation()
        guard let key = SearchKeyStore.key else { throw SearchError.researchNeedsKey }
        return try await tavily(query, key: key, research: true, session: session)
    }

    private static func tavilyProblem(_ error: Error) -> String {
        if case SearchError.http(let status) = error {
            switch status {
            case 401:
                return "The web search key was rejected, so only Wikipedia was searched. Tell the "
                    + "user to check the key on the Online page."
            case 429, 432, 433:
                return "The web search allowance is used up for now, so only Wikipedia was "
                    + "searched. Tell the user."
            default:
                break
            }
        }
        return "Web search was unavailable, so only Wikipedia was searched."
    }

    // MARK: - Tavily

    private static func tavily(_ query: String, key: String, research: Bool = false, session: URLSession = .shared) async throws -> Response {
        guard let endpoint = URL(string: "https://api.tavily.com/search") else {
            throw SearchError.badResponse
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "query": query,
            "search_depth": research ? "advanced" : "basic",
            "max_results": research ? 8 : 5,
            "include_answer": !research,
            "include_raw_content": research,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await fetchJSON(request, session: session)
        guard let items = json["results"] as? [[String: Any]] else { throw SearchError.badResponse }
        let results: [Result] = items.compactMap { item in
            guard let link = item["url"] as? String, let url = URL(string: link) else { return nil }
            return Result(
                title: HTMLText.plain(item["title"] as? String ?? link),
                url: url,
                site: site(of: url),
                summary: research ? String(HTMLText.plain(item["content"] as? String ?? "").prefix(1800)) : clip(HTMLText.plain(item["content"] as? String ?? "")),
                published: shortDate(item["published_date"] as? String),
                rawContent: (item["raw_content"] as? String).map { String($0.prefix(60_000)) }
            )
        }
        var response = Response(provider: .tavily, results: results)
        if let answer = json["answer"] as? String, !answer.isEmpty {
            response.answer = answer
        }
        return response
    }

    // MARK: - Wikipedia

    private static func wikipedia(_ query: String) async throws -> Response {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "5"),
            URLQueryItem(name: "srprop", value: "snippet"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "utf8", value: "1"),
        ]
        guard let url = components?.url else { throw SearchError.badResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let json = try await fetchJSON(request)
        let items = (json["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []
        var results: [Result] = []
        for (index, item) in items.enumerated() {
            guard let title = item["title"] as? String,
                  let url = URL(string: "https://en.wikipedia.org/wiki/" + wikiPath(title))
            else { continue }
            // Search snippets are fragments. The top two get the article's
            // opening paragraph instead, which usually holds the answer.
            var summary = HTMLText.plain(item["snippet"] as? String ?? "")
            if index < 2, let extract = await wikipediaExtract(title) {
                summary = extract
            }
            results.append(Result(title: title, url: url, site: "en.wikipedia.org",
                                  summary: clip(summary), published: nil))
        }
        return Response(provider: .wikipedia, results: results)
    }

    private static func wikipediaExtract(_ title: String) async -> String? {
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/" + wikiPath(title))
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let json = try? await fetchJSON(request),
              let extract = json["extract"] as? String, !extract.isEmpty
        else { return nil }
        return extract
    }

    private static func wikiPath(_ title: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let underscored = title.replacingOccurrences(of: " ", with: "_")
        return underscored.addingPercentEncoding(withAllowedCharacters: allowed) ?? underscored
    }

    // MARK: - Helpers

    private static func fetchJSON(_ request: URLRequest, session: URLSession = .shared) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SearchError.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchError.badResponse
        }
        return json
    }

    private static func site(of url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func clip(_ text: String) -> String {
        guard text.count > summaryLimit else { return text }
        return String(text.prefix(summaryLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "Tue, 11 Mar 2025 17:00:00 GMT" becomes "11 Mar 2025".
    private static func shortDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let range = raw.range(of: #"\d{1,2} [A-Za-z]{3} \d{4}"#, options: .regularExpression) {
            return String(raw[range])
        }
        return raw
    }
}

/// Plain text from small pieces of HTML, such as search snippets.
enum HTMLText {
    static func plain(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(stripped)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
                                    ("&#39;", "'"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        result = decodeNumeric(result)
        // Last, so "&amp;lt;" stays as the text "&lt;".
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func decodeNumeric(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#([xX]?)([0-9a-fA-F]+);") else { return text }
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let isHex = match.range(at: 1).length > 0
            let digits = source.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                output.unicodeScalars.append(scalar)
            } else {
                output += source.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }
}
