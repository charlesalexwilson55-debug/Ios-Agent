import Foundation

/// Web search for the model.
///
/// Exa is the primary discovery provider when configured. Tavily can broaden
/// research results and is the full-web fallback. Wikipedia remains available
/// for ordinary searches without a key, but research never degrades to it.
enum WebSearch {

    enum Provider: String, Sendable {
        case exa, tavily, combined, wikipedia

        var displayName: String {
            switch self {
            case .exa: "Exa"
            case .tavily: "Tavily"
            case .combined: "Exa and Tavily"
            case .wikipedia: "Wikipedia"
            }
        }
    }

    struct Result: Sendable {
        let title: String
        let url: URL
        let site: String
        let summary: String
        let published: String?
        var rawContent: String? = nil
        var provider: Provider? = nil
        var limitation: String? = nil
    }

    struct Response: Sendable {
        let provider: Provider
        let results: [Result]
        var answer: String?
        var limitation: String?
        var providers: [Provider] = []
    }

    enum SearchError: LocalizedError {
        case http(Int)
        case badResponse
        case researchNeedsKey
        case providerNeedsKey(Provider)
        case providersFailed(String)

        var errorDescription: String? {
            switch self {
            case .researchNeedsKey: "Research needs a working Exa or Tavily key. Add one in Sidebar → Online. Wikipedia alone cannot perform this research."
            case .providerNeedsKey(let provider): "Add a \(provider.displayName) key in Sidebar → Online before testing it."
            case .providersFailed(let detail): "Full-web research failed: \(detail)"
            case .http(401): "The web search key was rejected. Replace it in Sidebar → Online."
            case .http(429), .http(432), .http(433): "The web search provider's rate or usage limit was reached. Research stopped; this does not mean the person was not found."
            case .http(let status): "the search service answered with error \(status)."
            case .badResponse: "the search service sent something unreadable."
            }
        }
    }

    static let noKeyLimitation = "No web search key is set, so only Wikipedia was searched. "
        + "For news, prices or local information, tell the user that an Exa or Tavily key can "
        + "be added on the Online page."

    private static let userAgent = "Conduit/1.0 (personal on-device assistant for iOS)"
    private static let summaryLimit = 320

    static func search(_ query: String) async throws -> Response {
        if let exaKey = SearchKeyStore.exaKey {
            do {
                return try await exa(query, key: exaKey)
            } catch let exaError {
                try Task.checkCancellation()
                if let tavilyKey = SearchKeyStore.key {
                    do {
                        return try await tavily(query, key: tavilyKey)
                    } catch let tavilyError {
                        try Task.checkCancellation()
                        var response = try await wikipedia(query)
                        response.limitation = providerProblem(.exa, error: exaError)
                            + " " + providerProblem(.tavily, error: tavilyError)
                        return response
                    }
                }
                var response = try await wikipedia(query)
                response.limitation = providerProblem(.exa, error: exaError)
                return response
            }
        }
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
            response.limitation = providerProblem(.tavily, error: error)
            return response
        }
    }

    /// Searches one configured provider, used by the separate settings tests.
    static func search(_ query: String, provider: Provider, session: URLSession = .shared) async throws -> Response {
        try Task.checkCancellation()
        switch provider {
        case .exa:
            guard let key = SearchKeyStore.exaKey else { throw SearchError.providerNeedsKey(.exa) }
            return try await exa(query, key: key, session: session)
        case .tavily:
            guard let key = SearchKeyStore.key else { throw SearchError.providerNeedsKey(.tavily) }
            return try await tavily(query, key: key, session: session)
        case .wikipedia:
            return try await wikipedia(query, session: session)
        case .combined:
            throw SearchError.badResponse
        }
    }

    /// Research must never silently degrade into an encyclopedia-only search.
    static func research(_ query: String, session: URLSession = .shared) async throws -> Response {
        try Task.checkCancellation()
        guard SearchKeyStore.hasResearchKey else { throw SearchError.researchNeedsKey }

        if let exaKey = SearchKeyStore.exaKey {
            let exaResponse: Response
            do {
                exaResponse = try await exa(query, key: exaKey, research: true, session: session)
            } catch let exaError {
                try Task.checkCancellation()
                guard let tavilyKey = SearchKeyStore.key else { throw exaError }
                do {
                    var fallback = try await tavily(query, key: tavilyKey, research: true, session: session)
                    fallback.limitation = "Exa discovery failed (\(failureDetail(exaError))); Tavily results are shown instead."
                    return fallback
                } catch let tavilyError {
                    try Task.checkCancellation()
                    throw SearchError.providersFailed(
                        "Exa \(failureDetail(exaError)); Tavily \(failureDetail(tavilyError))."
                    )
                }
            }

            guard let tavilyKey = SearchKeyStore.key else { return exaResponse }
            do {
                let tavilyResponse = try await tavily(query, key: tavilyKey, research: true, session: session)
                return combined(exaResponse, tavilyResponse)
            } catch {
                try Task.checkCancellation()
                var response = exaResponse
                response.limitation = "Exa results are shown, but Tavily augmentation failed (\(failureDetail(error)))."
                return response
            }
        }

        guard let tavilyKey = SearchKeyStore.key else { throw SearchError.researchNeedsKey }
        return try await tavily(query, key: tavilyKey, research: true, session: session)
    }

    /// Extracts full text only for pages selected after discovery.
    static func extract(_ urls: [URL], session: URLSession = .shared) async throws -> [Result] {
        try Task.checkCancellation()
        guard !urls.isEmpty else { return [] }
        if let exaKey = SearchKeyStore.exaKey {
            do {
                return try await exaContents(urls, key: exaKey, session: session)
            } catch let exaError {
                try Task.checkCancellation()
                guard let tavilyKey = SearchKeyStore.key else { throw exaError }
                do {
                    let limitation = "Exa Contents failed (\(failureDetail(exaError))); Tavily extraction was used."
                    return try await tavilyExtract(urls, key: tavilyKey, session: session).map { result in
                        var result = result
                        if let existing = result.limitation {
                            result.limitation = limitation + " " + existing
                        } else {
                            result.limitation = limitation
                        }
                        return result
                    }
                } catch let tavilyError {
                    try Task.checkCancellation()
                    throw SearchError.providersFailed(
                        "Exa Contents \(failureDetail(exaError)); Tavily Extract \(failureDetail(tavilyError))."
                    )
                }
            }
        }
        guard let key = SearchKeyStore.key else { throw SearchError.researchNeedsKey }
        return try await tavilyExtract(urls, key: key, session: session)
    }

    private static func providerProblem(_ provider: Provider, error: Error) -> String {
        if case SearchError.http(let status) = error {
            switch status {
            case 401:
                return "The \(provider.displayName) key was rejected, so only Wikipedia was searched. Tell the user to check it on the Online page."
            case 429, 432, 433:
                return "The \(provider.displayName) allowance is used up for now, so only Wikipedia was searched. Tell the user."
            default:
                break
            }
        }
        return "\(provider.displayName) was unavailable, so only Wikipedia was searched."
    }

    private static func failureDetail(_ error: Error) -> String {
        if case SearchError.http(let status) = error { return "HTTP \(status)" }
        if case SearchError.badResponse = error { return "returned an unreadable response" }
        return error.localizedDescription
    }

    // MARK: - Exa

    private static func exa(_ query: String, key: String, research: Bool = false, session: URLSession = .shared) async throws -> Response {
        guard let endpoint = URL(string: "https://api.exa.ai/search") else { throw SearchError.badResponse }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "query": query,
            "type": "auto",
            "numResults": research ? 8 : 5,
        ]
        if !research {
            body["contents"] = ["highlights": true]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await fetchJSON(request, session: session)
        guard let items = json["results"] as? [[String: Any]] else { throw SearchError.badResponse }
        let results = items.compactMap { exaResult($0, fullText: false) }
        return Response(provider: .exa, results: results, providers: [.exa])
    }

    private static func exaContents(_ urls: [URL], key: String, session: URLSession) async throws -> [Result] {
        guard let endpoint = URL(string: "https://api.exa.ai/contents") else { throw SearchError.badResponse }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "urls": urls.map(\.absoluteString),
            "text": true,
        ])

        let json = try await fetchJSON(request, session: session)
        guard let items = json["results"] as? [[String: Any]] else { throw SearchError.badResponse }
        return items.compactMap { exaResult($0, fullText: true) }
    }

    private static func exaResult(_ item: [String: Any], fullText: Bool) -> Result? {
        guard let link = item["url"] as? String, let url = URL(string: link) else { return nil }
        let text = HTMLText.plain(item["text"] as? String ?? "")
        let highlights = (item["highlights"] as? [String] ?? []).map(HTMLText.plain).joined(separator: " ")
        let summary = HTMLText.plain(item["summary"] as? String ?? "")
        let bestSummary = !summary.isEmpty ? summary : (!highlights.isEmpty ? highlights : text)
        return Result(
            title: HTMLText.plain(item["title"] as? String ?? link),
            url: url,
            site: site(of: url),
            summary: fullText ? String(bestSummary.prefix(1800)) : clip(bestSummary),
            published: shortDate(item["publishedDate"] as? String),
            rawContent: fullText && !text.isEmpty ? String(text.prefix(60_000)) : nil,
            provider: .exa
        )
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
            "search_depth": "basic",
            "max_results": research ? 8 : 5,
            "include_answer": !research,
            "include_raw_content": false,
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
                rawContent: nil,
                provider: .tavily
            )
        }
        var response = Response(provider: .tavily, results: results, providers: [.tavily])
        if let answer = json["answer"] as? String, !answer.isEmpty {
            response.answer = answer
        }
        return response
    }

    private static func tavilyExtract(_ urls: [URL], key: String, session: URLSession) async throws -> [Result] {
        guard let endpoint = URL(string: "https://api.tavily.com/extract") else { throw SearchError.badResponse }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "urls": urls.map(\.absoluteString),
            "extract_depth": "basic",
            "format": "markdown",
        ])

        let json = try await fetchJSON(request, session: session)
        guard let items = json["results"] as? [[String: Any]] else { throw SearchError.badResponse }
        var results: [Result] = items.compactMap { item in
            guard let link = item["url"] as? String, let url = URL(string: link) else { return nil }
            let text = item["raw_content"] as? String ?? ""
            return Result(title: link, url: url, site: site(of: url), summary: clip(HTMLText.plain(text)),
                          published: nil, rawContent: String(text.prefix(60_000)), provider: .tavily)
        }
        for item in json["failed_results"] as? [[String: Any]] ?? [] {
            guard let link = item["url"] as? String, let url = URL(string: link) else { continue }
            results.append(Result(title: link, url: url, site: site(of: url), summary: "", published: nil,
                                  provider: .tavily,
                                  limitation: item["error"] as? String ?? "Tavily could not extract this page."))
        }
        return results
    }

    private static func combined(_ first: Response, _ second: Response) -> Response {
        var seen = Set<String>()
        let results = (first.results + second.results).filter { seen.insert(canonicalURL($0.url)).inserted }
        return Response(provider: .combined, results: results, providers: [.exa, .tavily])
    }

    private static func canonicalURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        if components?.path == "/" { components?.path = "" }
        return (components?.url?.absoluteString ?? url.absoluteString).lowercased()
    }

    // MARK: - Wikipedia

    private static func wikipedia(_ query: String, session: URLSession = .shared) async throws -> Response {
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

        let json = try await fetchJSON(request, session: session)
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
                                  summary: clip(summary), published: nil, provider: .wikipedia))
        }
        return Response(provider: .wikipedia, results: results, providers: [.wikipedia])
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw error
        }
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
