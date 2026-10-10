import SwiftUI
import UIKit
import WebKit

struct GeneratedFilesView: View {
    let project: FileProject
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(project.files) { file in GeneratedFileCard(file: file) }
            GeneratedProjectActions(project: project)
        }
    }
}

/// Whole-project actions stay available without replacing the streaming cards.
struct GeneratedProjectActions: View {
    let project: FileProject
    @State private var preview = false
    @State private var archiveURL: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                if let archiveURL { ShareLink(item: archiveURL) { Label("ZIP", systemImage: "square.and.arrow.up") } }
                if project.entryPoint != nil { Button { preview = true } label: { Label("Preview", systemImage: "safari") } }
                SendToPCButton { try project.export() }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: project.id) {
            do { archiveURL = try project.export() }
            catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $preview) {
            NavigationStack {
                LocalWebsitePreview(project: project)
                    .navigationTitle(project.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { preview = false } } }
            }
        }
    }
}

/// Generated pages get their project directory only; no native message bridge.
private struct LocalWebsitePreview: UIViewRepresentable {
    let project: FileProject
    func makeCoordinator() -> Coordinator { Coordinator(root: project.folder) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: """
            const meta = document.createElement('meta');
            meta.httpEquiv = 'Content-Security-Policy';
            meta.content = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'none'; frame-src 'none'; form-action 'none'";
            (document.head || document.documentElement).prepend(meta);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        if let url = project.entryPoint { view.loadFileURL(url, allowingReadAccessTo: project.folder) }
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        let root: URL
        init(root: URL) { self.root = root }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            let allowed = url.isFileURL && url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
            decisionHandler(allowed || url.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
