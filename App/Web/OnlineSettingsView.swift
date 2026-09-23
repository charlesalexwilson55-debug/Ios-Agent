import SwiftUI

/// Online access: the master switch, the web search key, and what leaves
/// the phone.
struct OnlineSettingsView: View {
    @AppStorage("conduit.online") private var online = true
    @State private var connectivity = Connectivity.shared
    @State private var hasKey = SearchKeyStore.hasKey
    @State private var keyDraft = ""
    @State private var testing = false
    @State private var testResult: TestResult?

    private enum TestResult {
        case working(Int)
        case noResults
        case failed(String)

        var message: String {
            switch self {
            case .working(let count):
                "Working: Tavily returned \(count) results."
            case .noResults:
                "Connected to Tavily, but this test returned no results. The key works; try again before relying on research."
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
                    Label(hasKey ? "Full-web research configured" : "Full-web research needs a key",
                          systemImage: hasKey ? "globe" : "exclamationmark.magnifyingglass")
                    if hasKey {
                        Label("Web search key saved", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Button {
                            test()
                        } label: {
                            HStack {
                                Text("Test web search")
                                Spacer()
                                if testing { ProgressView() }
                            }
                        }
                        .disabled(testing || !connectivity.isOnline)
                        Button("Remove key", role: .destructive) {
                            SearchKeyStore.save(nil)
                            hasKey = false
                            testResult = nil
                        }
                    } else {
                        SecureField("Paste your Tavily API key", text: $keyDraft)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Save key") {
                            SearchKeyStore.save(keyDraft)
                            keyDraft = ""
                            hasKey = SearchKeyStore.hasKey
                            if hasKey { test() }
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let testResult {
                        Label(testResult.message, systemImage: testResult.symbol)
                            .font(.footnote)
                            .foregroundStyle(testResult.color)
                    }
                } header: {
                    Text("Web search")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Conduit's text model runs on this phone. Tavily is a separate search provider that finds current web pages for the model to read.")
                        setupStep(1, "Open Tavily and create or sign in to your account.")
                        setupStep(2, "Create an API key in your Tavily dashboard, then paste it above and tap Save key.")
                        setupStep(3, "Tap Test web search. A working key can then search directories, employers and the wider web.")
                        Text("Research uses advanced searches and may consume more Tavily credits than an ordinary question.")
                        if let signUp = URL(string: "https://app.tavily.com") {
                            Link("Open Tavily setup", destination: signUp)
                        }
                    }
                }

                Section("What goes online") {
                    Label("Your search words go to Tavily, or to Wikipedia without a key.",
                          systemImage: "magnifyingglass")
                    Label("Pages the model reads load straight from their own sites, "
                        + "in a private browser that keeps no cookies.", systemImage: "doc.text")
                    Label("Weather asks Open-Meteo for the place, or your approximate location "
                        + "if you ask about where you are.", systemImage: "cloud.sun")
                    Label("Your conversations, contacts, calendar and the model itself stay on "
                        + "this phone.", systemImage: "lock.iphone")
                }
            }
            .navigationTitle("Online")
            .onAppear { hasKey = SearchKeyStore.hasKey }
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

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let response = try await WebSearch.research("medical practitioner hospital directory")
                if let limitation = response.limitation {
                    testResult = .failed(limitation)
                } else if response.results.isEmpty {
                    testResult = .noResults
                } else {
                    testResult = .working(response.results.count)
                }
            } catch {
                testResult = .failed(error.localizedDescription)
            }
            testing = false
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
