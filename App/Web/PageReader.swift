import UIKit
import WebKit

/// Loads a web page invisibly and returns its readable text.
///
/// A real web view rather than a plain download, because many sites build
/// their text with script and a raw download of them is empty. The web view
/// uses a throwaway data store, is kept off screen, and is torn down after
/// every read.
@MainActor
final class PageReader: NSObject {

    struct Page {
        let title: String
        let url: URL
        let text: String
        let links: [Link]
    }

    struct Link {
        let title: String
        let url: URL
        var summary: String = ""
    }

    enum ReadError: LocalizedError {
        case loadFailed(String)
        case noText

        var errorDescription: String? {
            switch self {
            case .loadFailed(let why):
                "the page did not load (\(why))."
            case .noText:
                "the page had almost no readable text. It may need a login or block automated reading."
            }
        }
    }

    private static let loadTimeout: Duration = .seconds(15)
    private static let renderDelay: Duration = .milliseconds(1200)
    private static let scriptTimeout: Duration = .seconds(5)
    private static let minimumText = 200

    static func read(_ url: URL) async throws -> Page {
        try await PageReader().load(url)
    }

    static func search(_ query: String) async throws -> [WebSearch.Result] {
        var url = URLComponents(string: "https://www.google.com/search")!
        url.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "udm", value: "14"),
                          URLQueryItem(name: "num", value: "10")]
        let page = try await PageReader().load(url.url!, search: true)
        return page.links.map { link in
            WebSearch.Result(title: link.title, url: link.url, site: link.url.host ?? "", summary: link.summary,
                             published: nil, provider: .browser)
        }
    }

    private static var pendingLinks: [URL: [Link]] = [:]
    static func takeLinks(for url: URL) -> [Link] { pendingLinks.removeValue(forKey: url) ?? [] }

    private var webView: WKWebView?
    private var navigation: CheckedContinuation<Void, Never>?
    private var script: CheckedContinuation<String?, Never>?
    private var loadError: String?

    private func load(_ url: URL, search: Bool = false) async throws -> Page {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(
            frame: CGRect(x: -10_000, y: 0, width: 390, height: 844),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        // In a window but off screen: WebKit throttles script in pages that
        // are not in a window.
        Self.keyWindow()?.addSubview(webView)
        self.webView = webView
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
            self.webView = nil
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            navigation = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 15))
            Task { [weak self] in
                try? await Task.sleep(for: PageReader.loadTimeout)
                self?.navigationEnded(error: nil)
            }
        }

        // Give script-built pages a moment to fill in.
        try? await Task.sleep(for: Self.renderDelay)

        let json = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            script = continuation
            webView.evaluateJavaScript(search ? Self.searchExtractor : Self.extractor) { [weak self] value, _ in
                let text = value as? String
                MainActor.assumeIsolated {
                    self?.scriptEnded(text)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: PageReader.scriptTimeout)
                self?.scriptEnded(nil)
            }
        }

        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ReadError.loadFailed(loadError ?? "no response")
        }
        let text = (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= (search ? 1 : Self.minimumText) else {
            if let loadError { throw ReadError.loadFailed(loadError) }
            throw ReadError.noText
        }
        let finalURL = (object["url"] as? String).flatMap { URL(string: $0) } ?? url
        let links = (object["links"] as? [[String: String]] ?? []).compactMap { item -> Link? in
            guard let raw = item["url"], let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return Link(title: String((item["title"] ?? raw).prefix(240)), url: url,
                        summary: String((item["summary"] ?? "").prefix(1200)))
        }
        let boundedLinks = Array(links.prefix(20))
        if Self.pendingLinks.count >= 12 { Self.pendingLinks.removeAll() }
        Self.pendingLinks[url] = boundedLinks
        return Page(title: object["title"] as? String ?? "", url: finalURL, text: text, links: boundedLinks)
    }

    private func navigationEnded(error: String?) {
        if let error, loadError == nil { loadError = error }
        guard let navigation else { return }
        self.navigation = nil
        navigation.resume()
    }

    private func scriptEnded(_ value: String?) {
        guard let script else { return }
        self.script = nil
        script.resume(returning: value)
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// Picks the main content, drops navigation and boilerplate, and returns
    /// the title, text and final address as JSON.
    private static let extractor = #"""
        (() => {
          const drop = 'script,style,noscript,svg,iframe,nav,footer,form,button,' +
            '[role="navigation"],[role="banner"],[role="contentinfo"]';
          const textOf = (el) => {
            if (!el) return '';
            el.querySelectorAll(drop).forEach((node) => node.remove());
            return el.innerText || el.textContent || '';
          };
          // Scan the entire rendered page before the research plan selects
          // bounded excerpts. Captions, article headers and subsequent articles
          // may contain the only occurrence of the requested person's name.
          let text = textOf(document.body);
          const seen = new Set();
          const links = Array.from(document.querySelectorAll('a[href]')).map(a => ({
            title: (a.innerText || a.textContent || '').replace(/\s+/g, ' ').trim(), url: a.href
          })).filter(link => {
            if (!link.title || !/^https?:\/\//i.test(link.url) || seen.has(link.url)) return false;
            seen.add(link.url); return true;
          }).slice(0, 20);
          text = text.split('\n')
            .map((line) => line.replace(/\s+/g, ' ').trim())
            .filter((line) => line.length > 1)
            .join('\n');
          return JSON.stringify({
            title: document.title || '',
            text,
            url: location.href,
            links
          });
        })()
        """#

    private static let searchExtractor = #"""
        (() => {
          const seen = new Set();
          const links = [];
          for (const heading of document.querySelectorAll('a h3')) {
            const anchor = heading.closest('a[href]');
            if (!anchor) continue;
            let target;
            try {
              target = new URL(anchor.href, location.href);
              if (/(^|\.)google\.[a-z.]+$/i.test(target.hostname)) {
                const next = target.searchParams.get('q') || target.searchParams.get('url');
                if (!next) continue;
                target = new URL(next);
              }
            } catch { continue; }
            if (!/^https?:$/.test(target.protocol) || /(^|\.)(google\.[a-z.]+|googleusercontent\.com|gstatic\.com)$/i.test(target.hostname)) continue;
            const title = (heading.innerText || heading.textContent || '').replace(/\s+/g, ' ').trim();
            if (!title || seen.has(target.href)) continue;
            // A headline often omits the searched name, while the snippet
            // includes an attributable photo caption. Keep one result's text,
            // never an ancestor containing multiple result headings.
            let summary = '';
            let node = heading.parentElement;
            for (let depth = 0; node && depth < 6; depth++, node = node.parentElement) {
              const headings = node.querySelectorAll ? node.querySelectorAll('h3').length : 1;
              if (headings > 1) break;
              const content = (node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim();
              if (content.length > 2500) break;
              if (content.length > title.length + 10) summary = content.replace(title, '').trim().slice(0, 1200);
            }
            const link = {title, url: target.href};
            if (summary) link.summary = summary;
            seen.add(target.href); links.push(link);
            if (links.length >= 10) break;
          }
          return JSON.stringify({title: document.title || '', url: location.href,
            text: links.map(link => link.title).join('\n'), links});
        })()
        """#
}

// @preconcurrency: WebKit calls these on the main thread.
extension PageReader: @preconcurrency WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationEnded(error: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationEnded(error: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        navigationEnded(error: error.localizedDescription)
    }
}
