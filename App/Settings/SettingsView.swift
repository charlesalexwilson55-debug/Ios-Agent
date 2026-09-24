import SwiftUI

/// Dark glass settings window. Archives live here so main navigation stays small.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case web, you, appearance, power, memory, research, permissions, information
        var id: String { rawValue }
        var title: String {
            switch self {
            case .web: "Web Searching"
            case .you: "You"
            case .appearance: "Appearance"
            case .power: "Power"
            case .memory: "Memory"
            case .research: "Research Archive"
            case .permissions: "Permissions"
            case .information: "Information"
            }
        }
        var symbol: String {
            switch self {
            case .web: "globe"
            case .you: "person.crop.circle"
            case .appearance: "paintpalette"
            case .power: "bolt"
            case .memory: "square.grid.2x2"
            case .research: "magnifyingglass"
            case .permissions: "hand.raised"
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
    @State private var badgeHeld = false

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
                case .web: OnlineSettingsView()
                case .you: ProfileSettingsView()
                case .appearance: AppearanceSettingsView()
                case .power: PowerSettingsView()
                case .memory: MemoryView(isWorking: isWorking, onOpen: onOpenChat)
                case .research:
                    ResearchArchiveView(isWorking: isWorking, canResume: canResume, onResume: onResumeResearch)
                case .permissions: PermissionsSettingsView()
                case .information: NavigationStack { CapabilitiesView() }
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 17) {
                        profileCard
                        settingsGroup("Your app", tabs: [.appearance, .power])
                        settingsGroup("Web", tabs: [.web])
                        settingsGroup("Saved work", tabs: [.memory, .research])
                        settingsGroup("About", tabs: [.permissions, .information])
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                }
                .scrollDisabled(badgeHeld)
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
            ModelBadge(model: usage.ranked.first?.model, held: $badgeHeld)
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
    @Binding var held: Bool
    @State private var tiltX = 0.0
    @State private var tiltY = 0.0

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
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                held = true
                tiltX = min(max(value.translation.width / 100, -1), 1)
                tiltY = min(max(value.translation.height / 100, -1), 1)
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3)) {
                    held = false
                    tiltX = 0
                    tiltY = 0
                }
            })
        .onDisappear { held = false }
        .accessibilityLabel(model.map { "Most used model: \($0), \(tier.name) tier" } ?? "No model usage yet")
    }
}

private struct PermissionsSettingsView: View {
    @State private var snapshot: Permissions.Snapshot?

    var body: some View {
        Form {
            if let snapshot {
                LabeledContent("Calendar", value: snapshot.calendar)
                LabeledContent("Reminders", value: snapshot.reminders)
                LabeledContent("Contacts", value: snapshot.contacts)
                LabeledContent("Notifications", value: snapshot.notifications)
            } else {
                ProgressView("Checking permissions")
            }
            Text("iOS asks when Conduit first needs access. Change denied access in iPhone Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { snapshot = await Permissions.shared.snapshot() }
    }
}

