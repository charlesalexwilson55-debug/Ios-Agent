import SwiftUI
import CoreMotion

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
        var symbol: String {
            switch self {
            case .connectors: "point.3.connected.trianglepath.dotted"
            case .web: "globe"
            case .you: "person.crop.circle"
            case .appearance: "paintpalette"
            case .power: "bolt"
            case .memory: "square.grid.2x2"
            case .research: "magnifyingglass"
            case .information: "info.circle"
            }
        }
    }

    let isWorking: Bool
    let canResume: Bool
    let onOpenChat: (ChatRecord) -> Void
    let onResumeResearch: (ResearchRun) -> Void
    let onClose: () -> Void
    @State private var selectedTab: Tab?
    @State private var profile = ProfileStore.shared
    @State private var usage = UsageStore.shared
    @AppStorage("conduit.profile.email") private var email = ""
    @AppStorage(NavigationStyle.storageKey) private var navigationStyle = NavigationStyle.icons.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if selectedTab != nil {
                    Button { withAnimation { selectedTab = nil } } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to settings")
                }
                Text(selectedTab?.title ?? "Settings").font(.title2.bold())
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

            if let selectedTab {
                Group {
                switch selectedTab {
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
            } else {
                ScrollView {
                    VStack(spacing: 17) {
                        profileCard
                        settingsGroup("Your app", tabs: [.appearance, .power])
                        VStack(spacing: 10) {
                            Text("Navigation bar").font(.headline)
                            Picker("Navigation bar", selection: $navigationStyle) {
                                ForEach(NavigationStyle.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        settingsGroup("Connections", tabs: [.connectors, .web])
                        settingsGroup("Saved work", tabs: [.memory, .research])
                        settingsGroup("About", tabs: [.information])
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(BackdropView())
    }

    private var profileCard: some View {
        VStack(spacing: 9) {
            Button { withAnimation { selectedTab = .you } } label: {
                VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 47, weight: .ultraLight))
                    .foregroundStyle(Color.conduitAccent)
                Text(profile.profile.name.isEmpty ? "Your profile" : profile.profile.name)
                    .font(.title3.bold())
                if !email.isEmpty {
                    Text(email).font(.subheadline).foregroundStyle(.secondary)
                }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit profile")
            ModelBadge(model: usage.ranked.first?.model)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func settingsGroup(_ title: String, tabs: [Tab]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            VStack(spacing: 0) {
                ForEach(tabs) { tab in
                    settingsRow(tab)
                    if tab != tabs.last { Divider().padding(.leading, 54) }
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 19))
        }
    }

    private func settingsRow(_ tab: Tab) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab } } label: {
            HStack(spacing: 12) {
                Image(systemName: tab.symbol)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color.conduitAccent)
                Text(tab.title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
    }
}

private struct ModelBadge: View {
    let model: String?
    @State private var held = false
    @State private var tiltX = 0.0
    @State private var tiltY = 0.0
    @State private var motion = CMMotionManager()

    private var tier: (name: String, color: Color) {
        let name = (model ?? "").lowercased()
        if name.contains("9b") || name.contains("8b") { return ("Advanced", .purple) }
        if name.contains("4b") || name.contains("3b") { return ("Versatile", .blue) }
        return ("Local model", .teal)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle")
            Text(model.map { "\(tier.name) · \($0)" } ?? "No model used yet")
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background {
            Capsule().fill(LinearGradient(
                colors: [tier.color.opacity(0.2), tier.color.opacity(held ? 0.8 : 0.4), .white.opacity(held ? 0.65 : 0.15)],
                startPoint: UnitPoint(x: 0.1 + tiltX * 0.3, y: 0.1 + tiltY * 0.3),
                endPoint: UnitPoint(x: 0.9 - tiltX * 0.3, y: 0.9 - tiltY * 0.3)))
        }
        .overlay { Capsule().strokeBorder(tier.color.opacity(0.7)) }
        .scaleEffect(held ? 1.22 : 1)
        .rotation3DEffect(.degrees(held ? tiltY * 13 : 0), axis: (x: 1, y: 0, z: 0))
        .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
            held = pressing
            if pressing {
                guard motion.isDeviceMotionAvailable else { return }
                motion.deviceMotionUpdateInterval = 1.0 / 30
                motion.startDeviceMotionUpdates(to: .main) { data, _ in
                    guard let gravity = data?.gravity else { return }
                    tiltX = gravity.x
                    tiltY = gravity.y
                }
            } else {
                motion.stopDeviceMotionUpdates()
                tiltX = 0
                tiltY = 0
            }
        }, perform: {})
        .onDisappear { motion.stopDeviceMotionUpdates() }
        .accessibilityLabel(model.map { "Most used model: \($0), \(tier.name) tier" } ?? "No model usage yet")
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
