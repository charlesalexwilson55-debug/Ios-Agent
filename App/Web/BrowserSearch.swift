import Foundation

/// Public search results, without a paid provider or a generated quick answer.
/// If the engine challenges access, fail explicitly rather than bypass it.
enum BrowserSearch {
    static func search(_ query: String, session: URLSession = .shared) async throws -> WebSearch.Response {
        #if canImport(UIKit)
        do {
            let results = try await PageReader.search(query)
            if !results.isEmpty { return .init(provider: .browser, results: results, providers: [.browser]) }
        } catch { try Task.checkCancellation() }
        #endif
        var url = URLComponents(string: "https://www.bing.com/search")!
        url.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "10"),
                          URLQueryItem(name: "setlang", value: "en"), URLQueryItem(name: "qs", value: "n")]
        var request = URLRequest(url: url.url!, timeoutInterval: 25)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Version/26.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 4_000_000, let html = String(data: data, encoding: .utf8) else {
            throw WebSearch.SearchError.providersFailed("Public web search did not return a readable page.")
        }
        let results = parse(html)
        guard !results.isEmpty else {
            throw WebSearch.SearchError.providersFailed("Public search returned no readable results or blocked automated access. Try another query or configure an optional search provider.")
        }
        return .init(provider: .browser, results: results, providers: [.browser])
    }

    static func parse(_ html: String) -> [WebSearch.Result] {
        func matches(_ pattern: String, _ text: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
                (0..<match.numberOfRanges).map { index in
                    match.range(at: index).location == NSNotFound ? "" : ns.substring(with: match.range(at: index))
                }
            }
        }
        var seen = Set<String>()
        return matches(#"<li\b[^>]*class=["'][^"']*\bb_algo\b[^"']*["'][^>]*>(.*?)</li>"#, html).compactMap { card -> WebSearch.Result? in
            guard let heading = matches(#"<h2\b[^>]*>.*?<a\b[^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#, card[1]).first,
                  let url = destination(HTMLText.decodeEntities(heading[1])), seen.insert(url.absoluteString).inserted else { return nil }
            let title = HTMLText.plain(heading[2])
            guard !title.isEmpty else { return nil }
            let snippet = matches(#"<p\b[^>]*>(.*?)</p>"#, card[1]).map { HTMLText.plain($0[1]) }.joined(separator: " ")
            return WebSearch.Result(title: title, url: url, site: url.host ?? "", summary: String(snippet.prefix(800)),
                                    published: nil, provider: .browser)
        }
    }

    static func destination(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host else { return nil }
        if host == "bing.com" || host.hasSuffix(".bing.com") {
            guard url.path == "/ck/a", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let encoded = components.queryItems?.first(where: { $0.name == "u" })?.value,
                  encoded.hasPrefix("a1") else { return nil }
            var base64 = String(encoded.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let data = Data(base64Encoded: base64), let target = String(data: data, encoding: .utf8),
                  let result = URL(string: target), ["http", "https"].contains(result.scheme?.lowercased() ?? ""),
                  let targetHost = result.host, targetHost != "bing.com", !targetHost.hasSuffix(".bing.com") else { return nil }
            return result
        }
        return url
    }
}
