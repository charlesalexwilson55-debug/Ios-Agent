import SwiftUI
import UIKit
import WebKit

struct GeneratedFilesView: View {
    let project: FileProject
    @State private var selection: VirtualFile?
    @State private var preview = false
    @State private var archiveURL: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(project.files) { file in
                HStack(spacing: 12) {
                    Button { selection = file } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text").font(.title2).foregroundStyle(Color.conduitAccent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.path).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.content.utf8.count), countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    Button { UIPasteboard.general.string = file.content; UIImpactFeedbackGenerator(style: .light).impactOccurred() } label: {
                        Image(systemName: "doc.on.doc").frame(width: 36, height: 36)
                    }.buttonStyle(.plain).accessibilityLabel("Copy \(file.path)")
                }
                .padding(14)
                .background(.black.opacity(0.5), in: .rect(cornerRadius: 18))
                .glassEffect(.regular.tint(.black.opacity(0.5)), in: .rect(cornerRadius: 18))
            }
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
        .sheet(item: $selection) { file in
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    Text(file.content).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).padding(18)
                }
                .background(BackdropView())
                .navigationTitle(file.path).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { selection = nil } }
                    ToolbarItem(placement: .topBarTrailing) { Button("Copy") { UIPasteboard.general.string = file.content } }
                }
            }
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
