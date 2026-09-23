import SwiftUI

/// Dark glass settings window. Archives live here so main navigation stays small.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case connectors, web, you, appearance, power, memory, research, information
        var id: String { rawValue }
        var title: String {
            switch self {
            case .connectors: "Connectors"
            case .web: "Web Searching"
            case .you: "You"
            case .appearance: "Appearance"
            case .power: "Power"
            case .memory: "Memory"
            case .research: "Research Archive"
            case .information: "Information"
            }
        }
    }

    let isWorking: Bool
    let canResume: Bool
    let onOpenChat: (ChatRecord) -> Void
    let onResumeResearch: (ResearchRun) -> Void
    let onClose: () -> Void
    @AppStorage("conduit.settings.tab") private var tabRaw = Tab.connectors.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.1), in: .circle)
                .accessibilityLabel("Close settings")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(Tab.allCases) { tab in
                        Button { tabRaw = tab.rawValue } label: {
                            Text(tab.title)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(tabRaw == tab.rawValue ? Color.conduitAccent.opacity(0.35) : .white.opacity(0.08), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
            .padding(.bottom, 10)

            Group {
                switch Tab(rawValue: tabRaw) ?? .connectors {
                case .connectors: ConnectorsSettingsView()
                case .web: OnlineSettingsView()
                case .you: ProfileSettingsView()
                case .appearance: AppearanceSettingsView()
                case .power: PowerSettingsView()
                case .memory: MemoryView(isWorking: isWorking, onOpen: onOpenChat)
                case .research:
                    ResearchArchiveView(isWorking: isWorking, canResume: canResume, onResume: onResumeResearch)
                case .information: NavigationStack { CapabilitiesView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Settings > Connectors: remote MCP servers.
struct ConnectorsSettingsView: View {
    @State private var store = MCPStore.shared
    @State private var editing: MCPServer?

    var body: some View {
        List {
            GoogleConnectSection()

            Section {
                if store.servers.isEmpty {
                    Text("No servers yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.servers) { server in
                    serverRow(server)
                        .contentShape(.rect)
                        .onTapGesture { editing = server }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { store.delete(server.id) }
                        }
                }
                Button {
                    editing = MCPServer()
                } label: {
                    Label("Add MCP server", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("MCP servers")
            } footer: {
                Text("Conduit connects to MCP servers on the internet that use the Streamable HTTP "
                    + "transport, with an optional access token. It cannot start servers on the phone, "
                    + "and servers that need a sign-in page are not supported yet.")
            }

            Section("How they are used") {
                Label("Name a server in your message, such as \u{201C}check my tasks in Linear\u{201D}, "
                    + "and its tools are offered for that message.", systemImage: "text.bubble")
                Label("What a server sends back is treated like web text: information, not instructions.",
                      systemImage: "exclamationmark.shield")
            }
            .font(.subheadline)
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $editing) { server in
            MCPServerEditor(server: server)
        }
    }

    private func serverRow(_ server: MCPServer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(server.enabled ? Color.conduitAccent : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name.isEmpty ? "Untitled" : server.name)
                Text(status(server))
                    .font(.footnote)
                    .foregroundStyle(server.lastError == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer()
            if store.refreshing.contains(server.id) {
                ProgressView()
            } else {
                Toggle("Enabled", isOn: Binding(
                    get: { server.enabled },
                    set: { store.setEnabled(server.id, $0) }
                ))
                .labelsHidden()
            }
        }
    }

    private func status(_ server: MCPServer) -> String {
        if let error = server.lastError { return error }
        if server.lastChecked == nil { return "Not checked yet" }
        let count = server.tools.count
        return count == 1 ? "1 tool" : "\(count) tools"
    }
}

/// Adding or changing one MCP server.
struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = MCPStore.shared
    @State private var draft: MCPServer
    @State private var token = ""
    @State private var removeToken = false
    @State private var isNew: Bool

    init(server: MCPServer) {
        _draft = State(initialValue: server)
        _isNew = State(initialValue: !MCPStore.shared.servers.contains { $0.id == server.id })
    }

    private var current: MCPServer? {
        store.servers.first { $0.id == draft.id }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: draft.url.trimmingCharacters(in: .whitespacesAndNewlines))?.host != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, for example Linear", text: $draft.name)
                        .textInputAutocapitalization(.words)
                    TextField("https://example.com/mcp", text: $draft.url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("The name is what you say in a message to use it.")
                }

                Section {
                    SecureField(tokenPlaceholder, text: $token)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !isNew, store.hasToken(draft.id) {
                        Toggle("Remove saved token", isOn: $removeToken)
                    }
                } header: {
                    Text("Access token (optional)")
                } footer: {
                    Text("Sent as a bearer token. Kept in the iPhone's Keychain, never in the chat.")
                }

                if let current, !isNew {
                    Section("Tools") {
                        if current.tools.isEmpty {
                            Text(current.lastError ?? "No tools found yet. Tap Save and check connection.")
                                .foregroundStyle(current.lastError == nil ? Color.secondary : Color.red)
                        }
                        ForEach(current.tools, id: \.name) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name).font(.body.monospaced())
                                if !tool.description.isEmpty {
                                    Text(tool.description)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                        }
                        if current.tools.count >= MCPStore.toolsPerServer {
                            Text("Only the first \(MCPStore.toolsPerServer) tools are used, to keep "
                                + "the model's prompt small enough for the phone.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        saveAndCheck()
                    } label: {
                        HStack {
                            Text("Save and check connection")
                            Spacer()
                            if store.refreshing.contains(draft.id) { ProgressView() }
                        }
                    }
                    .disabled(!canSave || store.refreshing.contains(draft.id))
                    if !isNew {
                        Button("Delete server", role: .destructive) {
                            store.delete(draft.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add server" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var tokenPlaceholder: String {
        !isNew && store.hasToken(draft.id) ? "Saved (type to replace)" : "Paste token"
    }

    private func save() {
        let newToken: String?
        if removeToken {
            newToken = ""
        } else {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            newToken = trimmed.isEmpty ? nil : trimmed
        }
        store.save(draft, token: newToken)
        token = ""
        removeToken = false
        isNew = false
    }

    private func saveAndCheck() {
        save()
        let id = draft.id
        Task { await store.refresh(id) }
    }
}
