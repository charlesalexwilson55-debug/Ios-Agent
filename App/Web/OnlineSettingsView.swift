import SwiftUI

/// Online access: the master switch, provider credentials, and what leaves
/// the phone.
struct OnlineSettingsView: View {
    @AppStorage("conduit.online") private var online = true
    @State private var connectivity = Connectivity.shared
    @State private var hasExaKey = SearchKeyStore.hasExaKey
    @State private var hasTavilyKey = SearchKeyStore.hasTavilyKey
    @State private var keyDraft = ""
    @State private var testingProvider: WebSearch.Provider?
    @State private var exaTestResult: TestResult?
    @State private var tavilyTestResult: TestResult?

    private enum TestResult {
        case working(WebSearch.Provider, Int)
        case noResults(WebSearch.Provider)
        case failed(String)

        var message: String {
            switch self {
            case .working(let provider, let count):
                "Working: \(provider.displayName) returned \(count) results."
            case .noResults(let provider):
                "Connected to \(provider.displayName), but this test returned no results. The key was accepted; try again before relying on research."
            case .failed(let message):
                "Not working: \(message)"
            }
        }

        var color: Color {
            switch self {
            case .working: .green
            case .noResults: .orange
            case .failed: .red
            }
        }

        var symbol: String {
            switch self {
            case .working: "checkmark.circle.fill"
            case .noResults: "exclamationmark.circle.fill"
            case .failed: "xmark.circle.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Let Conduit use the internet", isOn: $online)
                } footer: {
                    Text(statusText)
                }

                Section {
                    Label("Public web search available", systemImage: "globe")
                } footer: {
                    Text("Public search works without a key. Exa and Tavily are optional providers for more consistent discovery. Search engines may block automated requests; Conduit reports that rather than claiming nothing was found.")
                }

                Section {
                    SecureField("Import a Tavily or Exa key", text: $keyDraft)
                        .textContentType(.password).autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if keyDraft.count >= 20, SearchKeyKind.detect(keyDraft) == nil {
                        Text("Key format not recognised. Paste the full Tavily or Exa key.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if hasExaKey {
                        Label("Exa key saved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Remove Exa key", role: .destructive) { SearchKeyStore.saveExa(nil); refreshKeyState(); exaTestResult = nil }
                    }
                    if hasTavilyKey {
                        Label("Tavily key saved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Remove Tavily key", role: .destructive) { SearchKeyStore.saveTavily(nil); refreshKeyState(); tavilyTestResult = nil }
                    }
                    if testingProvider != nil { ProgressView("Checking key…") }
                    if let result = exaTestResult { Text(result.message).font(.footnote).foregroundStyle(result.color) }
                    if let result = tavilyTestResult { Text(result.message).font(.footnote).foregroundStyle(result.color) }
                } header: {
                    Text("Search keys")
                } footer: {
                    Text("Paste either key here. Conduit identifies its provider and saves it automatically. Research always uses thorough discovery.")
                }

                Section("What goes online") {
                    Label("Ordinary searches go to Exa first, then Tavily when configured. Without either key, they use Wikipedia.",
                          systemImage: "magnifyingglass")
                    Label("Research search words go to Exa and may also go to Tavily to broaden the source pool.",
                          systemImage: "binoculars")
                    Label("When research selects pages for full text, their URLs are sent to Exa Contents or Tavily Extract. Pages may also load directly from their own sites.",
                          systemImage: "doc.text")
                    Label("Weather asks Open-Meteo for the place, or your approximate location if you ask about where you are.",
                          systemImage: "cloud.sun")
                    Label("Your conversations, contacts, calendar, provider keys and the model itself stay on this phone.",
                          systemImage: "lock.iphone")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Web Searching")
            .onAppear { refreshKeyState() }
            .task(id: keyDraft) {
                do { try await Task.sleep(for: .milliseconds(700)); try Task.checkCancellation(); importKey() }
                catch { }
            }
        }
    }

    private func importKey() {
        guard let kind = SearchKeyKind.detect(keyDraft) else { return }
        let provider: WebSearch.Provider = kind == .tavily ? .tavily : .exa
        if kind == .tavily { SearchKeyStore.saveTavily(keyDraft); tavilyTestResult = nil }
        else { SearchKeyStore.saveExa(keyDraft); exaTestResult = nil }
        keyDraft = ""
        refreshKeyState()
        if online && connectivity.isOnline && testingProvider == nil { test(provider) }
    }

    private var statusText: String {
        if !online {
            return "Off. The model answers only from what it already knows."
        }
        if !connectivity.isOnline {
            return "No signal right now. The model will answer offline until the phone reconnects."
        }
        return "On. The model can search the web, read pages and check the weather. "
            + "Turn it off here or with the globe button in the chat bar."
    }

    private func refreshKeyState() {
        hasExaKey = SearchKeyStore.hasExaKey
        hasTavilyKey = SearchKeyStore.hasTavilyKey
    }

    private func test(_ provider: WebSearch.Provider) {
        testingProvider = provider
        setTestResult(nil, for: provider)
        Task {
            do {
                let response = try await WebSearch.search("medical practitioner hospital directory", provider: provider)
                if let limitation = response.limitation {
                    setTestResult(.failed(limitation), for: provider)
                } else if response.results.isEmpty {
                    setTestResult(.noResults(provider), for: provider)
                } else {
                    setTestResult(.working(provider, response.results.count), for: provider)
                }
            } catch {
                setTestResult(.failed(error.localizedDescription), for: provider)
            }
            testingProvider = nil
        }
    }

    private func setTestResult(_ result: TestResult?, for provider: WebSearch.Provider) {
        if provider == .exa {
            exaTestResult = result
        } else {
            tavilyTestResult = result
        }
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(number)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.conduitAccent, in: .circle)
            Text(text)
        }
    }
}
