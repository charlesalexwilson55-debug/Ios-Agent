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

    private var webView: WKWebView?
    private var navigation: CheckedContinuation<Void, Never>?
    private var script: CheckedContinuation<String?, Never>?
    private var loadError: String?

    private func load(_ url: URL) async throws -> Page {
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
            webView.evaluateJavaScript(Self.extractor) { [weak self] value, _ in
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
        guard text.count >= Self.minimumText else {
            if let loadError { throw ReadError.loadFailed(loadError) }
            throw ReadError.noText
        }
        let finalURL = (object["url"] as? String).flatMap { URL(string: $0) } ?? url
        return Page(title: object["title"] as? String ?? "", url: finalURL, text: text)
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
          const drop = 'script,style,noscript,svg,iframe,nav,footer,header,aside,form,button,' +
            '[aria-hidden="true"],[role="navigation"],[role="banner"],[role="contentinfo"]';
          const textOf = (el) => {
            if (!el) return '';
            el.querySelectorAll(drop).forEach((node) => node.remove());
            return el.innerText || el.textContent || '';
          };
          let text = textOf(document.querySelector('article') ||
            document.querySelector('main') || document.querySelector('[role="main"]'));
          if (text.trim().length < 400) text = textOf(document.body);
          text = text.split('\n')
            .map((line) => line.replace(/\s+/g, ' ').trim())
            .filter((line) => line.length > 1)
            .join('\n');
          return JSON.stringify({
            title: document.title || '',
            text: text.slice(0, 20000),
            url: location.href
          });
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
