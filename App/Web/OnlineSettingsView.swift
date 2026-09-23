import SwiftUI

/// Online access: the master switch, provider credentials, and what leaves
/// the phone.
struct OnlineSettingsView: View {
    @AppStorage("conduit.online") private var online = true
    @State private var connectivity = Connectivity.shared
    @State private var hasExaKey = SearchKeyStore.hasExaKey
    @State private var hasTavilyKey = SearchKeyStore.hasTavilyKey
    @State private var exaDraft = ""
    @State private var tavilyDraft = ""
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
                    Label(hasExaKey || hasTavilyKey ? "Full-web research configured" : "Full-web research needs a key",
                          systemImage: hasExaKey || hasTavilyKey ? "globe" : "exclamationmark.magnifyingglass")
                } footer: {
                    Text("Exa is the primary discovery provider. Tavily broadens results when both are configured and is used when Exa is unavailable.")
                }

                providerSection(
                    provider: .exa,
                    hasKey: hasExaKey,
                    draft: $exaDraft,
                    result: exaTestResult,
                    placeholder: "Paste your Exa API key",
                    save: {
                        SearchKeyStore.saveExa(exaDraft)
                        exaDraft = ""
                        hasExaKey = SearchKeyStore.hasExaKey
                        exaTestResult = nil
                    },
                    remove: {
                        SearchKeyStore.saveExa(nil)
                        hasExaKey = false
                        exaTestResult = nil
                    }
                )

                providerSection(
                    provider: .tavily,
                    hasKey: hasTavilyKey,
                    draft: $tavilyDraft,
                    result: tavilyTestResult,
                    placeholder: "Paste your Tavily API key",
                    save: {
                        SearchKeyStore.saveTavily(tavilyDraft)
                        tavilyDraft = ""
                        hasTavilyKey = SearchKeyStore.hasTavilyKey
                        tavilyTestResult = nil
                    },
                    remove: {
                        SearchKeyStore.saveTavily(nil)
                        hasTavilyKey = false
                        tavilyTestResult = nil
                    }
                )

                Section("Provider setup") {
                    setupStep(1, "Create an API key with Exa, Tavily, or both.")
                    setupStep(2, "Paste each key in its own section and tap its Save button.")
                    setupStep(3, "Test each saved key separately before relying on research.")
                    if let exaSetup = URL(string: "https://dashboard.exa.ai/api-keys") {
                        Link("Open Exa setup", destination: exaSetup)
                    }
                    if let tavilySetup = URL(string: "https://app.tavily.com") {
                        Link("Open Tavily setup", destination: tavilySetup)
                    }
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
            .navigationTitle("Online")
            .onAppear { refreshKeyState() }
        }
    }

    @ViewBuilder
    private func providerSection(
        provider: WebSearch.Provider,
        hasKey: Bool,
        draft: Binding<String>,
        result: TestResult?,
        placeholder: String,
        save: @escaping () -> Void,
        remove: @escaping () -> Void
    ) -> some View {
        Section {
            if hasKey {
                Label("\(provider.displayName) key saved", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Button {
                    test(provider)
                } label: {
                    HStack {
                        Text("Test \(provider.displayName)")
                        Spacer()
                        if testingProvider == provider { ProgressView() }
                    }
                }
                .disabled(testingProvider != nil || !connectivity.isOnline)
                Button("Remove \(provider.displayName) key", role: .destructive, action: remove)
            } else {
                SecureField(placeholder, text: draft)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save \(provider.displayName) key", action: save)
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let result {
                Label(result.message, systemImage: result.symbol)
                    .font(.footnote)
                    .foregroundStyle(result.color)
            }
        } header: {
            Text(provider == .exa ? "Exa discovery" : "Tavily augmentation")
        } footer: {
            if provider == .exa {
                Text("Exa finds the primary research source pool. Discovery returns metadata and short highlights; full text is requested only for selected pages.")
            } else {
                Text("Tavily adds a second source pool within the two-call research budget and provides fallback discovery when Exa fails.")
            }
        }
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
