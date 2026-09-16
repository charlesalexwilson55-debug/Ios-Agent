import SwiftUI

/// Online access: the master switch, the web search key, and what leaves
/// the phone.
struct OnlineSettingsView: View {
    @AppStorage("conduit.online") private var online = true
    @State private var connectivity = Connectivity.shared
    @State private var hasKey = SearchKeyStore.hasKey
    @State private var keyDraft = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Let Conduit use the internet", isOn: $online)
                } footer: {
                    Text(statusText)
                }

                Section {
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
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Web search")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Without a key, Conduit searches Wikipedia only, which is fine for "
                            + "general knowledge but has no news, prices or local results.")
                        Text("A free Tavily account gives 1,000 full web searches a month with no "
                            + "card: sign up, copy your API key (it starts with tvly-) and paste it above.")
                        if let signUp = URL(string: "https://app.tavily.com") {
                            Link("Open tavily.com", destination: signUp)
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
                let response = try await WebSearch.search("weather forecast")
                if let limitation = response.limitation {
                    testResult = "Not working: " + limitation
                } else {
                    testResult = "Working: \(response.results.count) results from Tavily."
                }
            } catch {
                testResult = "The search failed: \(error.localizedDescription)"
            }
            testing = false
        }
    }
}
