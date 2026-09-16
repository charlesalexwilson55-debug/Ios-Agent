import Foundation
import WebKit

/// Code execution, for exact maths and for checking code the model writes.
///
/// A 4-bit model doing arithmetic token by token gets long multiplication,
/// large numbers and date maths wrong often enough to matter. Running the
/// calculation instead makes those answers exact. It also lets the model test
/// a snippet before handing it over, rather than guessing whether it works.
///
/// JavaScript is the language because iOS ships a JavaScript engine and no
/// other interpreter; running Python on-device would mean embedding one.
@MainActor
final class CodeTools: ToolProviding {

    private static let timeout: Duration = .seconds(10)
    private static let maxResultCharacters = 2_000
    private static let maxConsoleCharacters = 3_000

    let specs: [ToolDescriptor] = [
        ToolDescriptor(
            name: "run_javascript",
            description: "Run JavaScript in a sandbox on this phone. Returns the value of the "
                + "last expression and anything printed with console.log. Use it for any "
                + "arithmetic beyond the trivial, percentages, unit and date calculations, "
                + "and to test code you have written before giving it to the user. "
                + "No network, no files, 10 second limit. Use BigInt (123n) for integers "
                + "larger than 2^53.",
            params: [
                .required("code", .string,
                          "JavaScript source. The final expression is the returned value."),
            ],
            friction: .silent,
            category: "code"
        ),
    ]

    func run(_ name: String, arguments: ArgumentValue) async -> ToolOutcome {
        guard name == "run_javascript" else {
            return .failure(name, "CodeTools cannot handle \(name).")
        }
        guard let code = arguments.string("code"), !code.isEmpty else {
            return .badArgument("run_javascript", "code", "JavaScript source to run")
        }

        let output = await JavaScriptSandbox.run(code, timeout: Self.timeout)
        var detail: [String: String] = [:]
        let console = Self.clip(output.logs.joined(separator: "\n"), to: Self.maxConsoleCharacters)
        if !console.isEmpty { detail["console"] = console }

        if output.timedOut {
            return .failure("run_javascript",
                            "The code ran for more than 10 seconds and was stopped. "
                                + "Look for an infinite loop or a much slower approach than needed.",
                            detail: detail)
        }
        if let error = output.error {
            return .failure("run_javascript",
                            "The code threw an error: \(Self.clip(error, to: 600)). "
                                + "Fix the code and run it again.",
                            detail: detail)
        }

        let value = Self.clip(output.value ?? "undefined", to: Self.maxResultCharacters)
        detail["result"] = value
        return .success("run_javascript", "Ran code → \(Self.clip(value, to: 80))", detail: detail)
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + " …[truncated]"
    }
}

/// One-shot JavaScript runner backed by a hidden WKWebView.
///
/// A web view rather than a bare JSContext because it runs in a separate web
/// content process that can be torn down. JavaScriptCore on a background thread
/// has no public way to stop a script stuck in a loop, so a runaway snippet
/// would burn a core until the app quit. Here, dropping the web view ends the
/// process. A content security policy blocks network access, so nothing the
/// model writes can send data anywhere.
@MainActor
final class JavaScriptSandbox: NSObject {
    struct Output {
        var value: String?
        var logs: [String] = []
        var error: String?
        var timedOut = false
    }

    private var webView: WKWebView?
    private var pageReady: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Output, Never>?

    static func run(_ code: String, timeout: Duration) async -> Output {
        let sandbox = JavaScriptSandbox()
        return await sandbox.execute(code, timeout: timeout)
    }

    private static let page = """
        <!doctype html><meta http-equiv="Content-Security-Policy" \
        content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'">
        """

    /// Body of an async function, called with `source` bound to the code.
    /// Indirect eval runs the code at global scope and yields the value of its
    /// last expression, which is what makes `2 ** 64n` a complete program.
    private static let harness = """
        const logs = [];
        const show = (v) => {
          if (typeof v === 'string') return v;
          if (typeof v === 'bigint') return v.toString() + 'n';
          if (typeof v === 'function') return v.toString();
          try { const s = JSON.stringify(v); return s === undefined ? String(v) : s; }
          catch (e) { return String(v); }
        };
        for (const k of ['log', 'info', 'warn', 'error', 'debug']) {
          console[k] = (...args) => { if (logs.length < 200) logs.push(args.map(show).join(' ')); };
        }
        try {
          let value = (0, eval)(source);
          if (value && typeof value.then === 'function') value = await value;
          return { value: value === undefined ? null : show(value), logs: logs };
        } catch (e) {
          return { error: String(e && e.stack ? e.stack : e), logs: logs };
        }
        """

    private func execute(_ code: String, timeout: Duration) async -> Output {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pageReady = continuation
            webView.loadHTMLString(Self.page, baseURL: nil)
        }

        let output = await withCheckedContinuation { (continuation: CheckedContinuation<Output, Never>) in
            pending = continuation

            // The completion-handler form, not the async one: the async form
            // keeps the web view alive until the script returns, which for an
            // infinite loop is never, so the timeout could not tear it down.
            webView.callAsyncJavaScript(
                Self.harness,
                arguments: ["source": code],
                in: nil,
                in: .defaultClient
            ) { [weak self] outcome in
                // WebKit delivers this on the main thread; say so explicitly in
                // case the SDK does not annotate the handler as main-actor.
                MainActor.assumeIsolated {
                    switch outcome {
                    case .success(let value):
                        self?.finish(JavaScriptSandbox.decode(value))
                    case .failure(let error):
                        self?.finish(Output(error: error.localizedDescription))
                    }
                }
            }

            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(Output(timedOut: true))
            }
        }

        // Dropping the web view ends its content process, which is the only
        // public way to stop a script that is still running.
        self.webView?.navigationDelegate = nil
        self.webView = nil
        return output
    }

    private func finish(_ output: Output) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: output)
    }

    private func pageLoaded() {
        guard let pageReady else { return }
        self.pageReady = nil
        pageReady.resume()
    }

    private static func decode(_ raw: Any?) -> Output {
        guard let dictionary = raw as? [String: Any] else {
            return Output(error: "The sandbox returned an unexpected result.")
        }
        var output = Output()
        output.value = dictionary["value"] as? String
        output.logs = dictionary["logs"] as? [String] ?? []
        output.error = dictionary["error"] as? String
        return output
    }
}

// @preconcurrency: WebKit calls these on the main thread.
extension JavaScriptSandbox: @preconcurrency WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded()
    }

    // A failed load still leaves a usable blank document to run script in, so
    // execution carries on rather than hanging on a page that never arrives.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoaded()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        pageLoaded()
    }
}
