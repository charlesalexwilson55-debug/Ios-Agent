import SwiftUI
import UIKit

@main
struct ConduitApp: App {
    @State private var catalog = ModelCatalog()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(catalog)
                // Glass surfaces are designed against a real backdrop; a plain
                // system background gives them nothing to refract and they
                // read as flat grey rectangles.
                .background(BackdropView())
                .modifier(AppearanceModifier())
        }
    }
}

/// Applies the theme and highlight colour chosen in Settings > Appearance.
private struct AppearanceModifier: ViewModifier {
    @AppStorage(Appearance.themeKey) private var theme = Appearance.Theme.system.rawValue
    @AppStorage(Appearance.accentKey) private var accentHex = ""

    func body(content: Content) -> some View {
        content
            .preferredColorScheme((Appearance.Theme(rawValue: theme) ?? .system).scheme)
            .tint(Color(hex: accentHex) ?? .accentColor)
    }
}

struct RootView: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.scenePhase) private var scenePhase

    /// One runner for the app's lifetime. Recreating it would drop the loaded
    /// weights, and reloading those is a 20-60 second operation on a phone.
    @State private var runner = ModelRunner()
    @State private var session: AgentSession?
    @State private var draft = ""
    @State private var attachments: [PhotoAttachment] = []
    @State private var loadingState: ModelLoadingState = .idle
    /// Persisted so the choice survives relaunches. On by default: correct
    /// answers to maths and code matter more than speed on those questions.
    @AppStorage("conduit.thinking") private var thinking = true
    @AppStorage("conduit.online") private var online = true
    /// Research mode. Not persisted: it changes what every message does, so
    /// it starts off each launch.
    @State private var research = false
    @State private var page: AppPage = .chat
    @State private var sidebarOpen = false
    @State private var personas = PersonaStore.shared
    @State private var menuOpen = false
    /// Set by the plus menu so the Personalities page opens a new one.
    @State private var startNewPersona = false
    /// The plus menu's work level, and whether Auto picks it per message.
    @AppStorage("conduit.level") private var levelRaw = WorkLevel.normal.rawValue
    @AppStorage("conduit.autoLevel") private var autoLevel = false
    /// Views that draw with the chosen accent colour and text size are
    /// rebuilt when either changes.
    @AppStorage(Appearance.accentKey) private var accentHex = ""
    @AppStorage(Appearance.textSizeKey) private var textSize = ""

    var body: some View {
        ZStack {
            // The chat stays in the hierarchy on every page, so leaving it and
            // coming back keeps the scroll position and any unsent draft.
            chatPage
                .opacity(page == .chat ? 1 : 0)
                .allowsHitTesting(page == .chat)
                .accessibilityHidden(page != .chat)
            if page != .chat {
                otherPage
                    .transition(.opacity)
            }
            SidebarOverlay(page: $page, isOpen: $sidebarOpen)
                .id(appearanceKey)
        }
        .animation(.easeInOut(duration: 0.2), value: page)
        .task {
            let newSession = AgentSession(runner: runner, registry: ToolRegistry.standard())
            newSession.thinkingEnabled = thinking
            newSession.onlineEnabled = online
            newSession.researchEnabled = research
            newSession.persona = personas.selected
            newSession.workLevel = WorkLevel(rawValue: levelRaw) ?? .normal
            newSession.autoLevel = autoLevel
            session = newSession
            Diagnostics.log("app.launch avail=\(Diagnostics.availableMB)MB")
            VolumeKeys.shared.onQuickPress = {
                withAnimation { sidebarOpen.toggle() }
            }
            VolumeKeys.shared.start()

            // Read before loading, which writes a marker of its own.
            let unfinished = Diagnostics.takeUnfinishedWork()
            if let unfinished {
                Diagnostics.log("app.previous-run-died-during \(unfinished)")
                newSession.noteInterruptedWork(unfinished)
            }
            let diedWhileLoading = unfinished?.hasPrefix("load") ?? false

            await catalog.refresh()
            newSession.visionModelDirectory = catalog.visionModels.first?.directory
            // Reload whatever was in use last launch, so the app comes back
            // ready rather than making the user pick again every time. Not if
            // loading it is what killed the last run: that would crash again
            // on every launch.
            if let previous = catalog.selectedModel, !diedWhileLoading {
                await load(previous)
            } else {
                page = .models
            }
            consumePendingTask()
        }
        .task {
            let warnings = NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification)
            for await _ in warnings {
                Diagnostics.log("memory.warning avail=\(Diagnostics.availableMB)MB "
                    + "generating=\(session?.isGenerating ?? false)")
            }
        }
        // A task handed over by Siri or a Shortcut while the app was already
        // running arrives on foreground rather than at launch.
        .onChange(of: thinking) { _, enabled in
            session?.thinkingEnabled = enabled
        }
        .onChange(of: online) { _, enabled in
            session?.onlineEnabled = enabled
        }
        .onChange(of: research) { _, enabled in
            session?.researchEnabled = enabled
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                consumePendingTask()
                VolumeKeys.shared.start()
            case .inactive, .background:
                session?.leavingForeground()
                if phase == .background { VolumeKeys.shared.stop() }
            default: break
            }
        }
        .overlay(alignment: .top) {
            if case .loading = loadingState { loadingBanner }
        }
    }

    /// Chat, with the command bar. A NavigationStack purely to host the
    /// toolbar: without one the toolbar modifier is silently ignored and the
    /// New button never appears. The bar itself is kept hidden so the
    /// transcript runs to the top edge under the glass.
    private var chatPage: some View {
        NavigationStack {
            TranscriptView(
                entries: session?.transcript ?? [],
                accent: personas.selected?.color ?? Color.conduitAccent,
                onShowDraft: { index, id in session?.showDraft(index, of: id) },
                onCancelActivity: { id, entryID in session?.cancelActivity(id, in: entryID) },
                isWorking: session?.isWorking ?? false,
                onSelectResearchCandidate: { id, entryID in session?.selectResearchCandidate(id, in: entryID) }
            )
            // A tap anywhere above the bar closes the plus menu.
            .overlay {
                if menuOpen {
                    Color.black.opacity(0.06)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .onTapGesture { menuOpen = false }
                        .accessibilityHidden(true)
                }
            }
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session?.clear()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(session?.transcript.isEmpty ?? true)
                    .accessibilityLabel("New conversation")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            GlassCommandBar(
                draft: $draft,
                thinking: $thinking,
                online: $online,
                research: $research,
                menuOpen: $menuOpen,
                level: levelBinding,
                autoLevel: $autoLevel,
                attachments: $attachments,
                personas: personas.personas,
                selectedPersona: personas.selected,
                onSelectPersona: { personas.select($0) },
                onManagePersonas: { createNew in
                    startNewPersona = createNew
                    page = .personalities
                },
                isWorking: session?.isWorking ?? false,
                isModelLoaded: isReady,
                onSend: send,
                onStop: { session?.cancel() }
            )
        }
        // Edits to the personality in use apply from the next message.
        .onChange(of: personas.selected) { _, persona in
            session?.persona = persona
        }
        .onChange(of: personas.selectedID) { _, _ in
            if let persona = personas.selected {
                levelRaw = persona.level.rawValue
                autoLevel = persona.autoLevel
            }
            loadModel(for: personas.selected)
        }
        .onChange(of: levelRaw) { _, raw in
            session?.workLevel = WorkLevel(rawValue: raw) ?? .normal
        }
        .onChange(of: autoLevel) { _, enabled in
            session?.autoLevel = enabled
        }
        .id(appearanceKey)
        .onChange(of: page) { _, _ in
            menuOpen = false
        }
    }

    @ViewBuilder
    private var otherPage: some View {
        switch page {
        case .chat:
            EmptyView()
        case .libraries:
            LibrariesView()
        case .memory:
            MemoryView()
        case .images:
            ImagesView()
        case .personalities:
            PersonasView(startNew: $startNewPersona)
                .environment(catalog)
        case .directions:
            DirectionsView()
        case .online:
            OnlineSettingsView()
        case .models:
            ModelPickerSheet(onSelect: selectFromPage, loadingState: loadingState, showsDoneButton: false)
                .environment(catalog)
        case .capabilities:
            NavigationStack {
                CapabilitiesView()
            }
        case .settings:
            SettingsView()
        }
    }

    private var levelBinding: Binding<WorkLevel> {
        Binding(
            get: { WorkLevel(rawValue: levelRaw) ?? .normal },
            set: { levelRaw = $0.rawValue }
        )
    }

    private var appearanceKey: String {
        accentHex + "|" + textSize
    }

    private func selectFromPage(_ model: DiscoveredModel) {
        session?.visionModelDirectory = catalog.visionModels.first?.directory
        select(model)
        page = .chat
    }

    private var isReady: Bool {
        if case .loading = loadingState { return false }
        return catalog.selectedModel != nil
    }

    private var loadingBanner: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Loading model…")
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func send() {
        let text = draft
        let images = attachments.map(\.data)
        draft = ""
        attachments = []
        session?.submit(text, imageData: images)
    }

    /// Runs a task handed over by Siri or a Shortcut.
    ///
    /// Held until the model has finished loading: submitting into a session
    /// with no weights loaded would fail with "no model loaded" and the user
    /// would have to retype what they just dictated.
    private func consumePendingTask() {
        guard let task = PendingTask.take() else { return }
        guard isReady else {
            Task {
                // Bounded wait: a model that fails to load must not leave a
                // task spinning here forever, and a minute is well past the
                // point where the user would rather just retype it.
                for _ in 0..<150 {
                    if isReady { session?.submit(task); return }
                    if case .failed = loadingState { return }
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            return
        }
        session?.submit(task)
    }

    /// Loads the model a personality asks for, when it is on the phone and
    /// not already loaded.
    private func loadModel(for persona: Persona?) {
        guard let persona else { return }
        let wanted = persona.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return }
        guard let model = ModelMatcher.match(wanted, in: catalog.models) else {
            session?.note("\(persona.name) asks for the model \u{201C}\(wanted)\u{201D}, which is not "
                + "on this phone, so the current model stays loaded.")
            return
        }
        guard model.id != catalog.selectedModelID else { return }
        // A model cannot be swapped out from under an answer being written.
        if session?.isWorking ?? false { session?.cancel() }
        select(model)
    }

    private func select(_ model: DiscoveredModel) {
        catalog.select(modelID: model.id)
        Task { await load(model) }
    }

    private func load(_ model: DiscoveredModel) async {
        loadingState = .loading(model.id)
        do {
            try await runner.load(
                directory: model.directory,
                displayName: model.displayName,
                adapterDirectory: catalog.selectedAdapter?.directory
            )
            loadingState = .idle
        } catch {
            loadingState = .failed(error.localizedDescription)
            // Surfaced on the Models page rather than as an alert: the fix is
            // almost always picking a different, smaller model, and that is
            // where the user does it.
            page = .models
        }
    }
}

/// A quiet gradient behind the glass.
///
/// Liquid Glass samples and refracts what is behind it, so a flat fill makes
/// every glass surface look inert. A soft, low-contrast gradient gives the
/// material something to work with without competing with the text.
private struct BackdropView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Appearance.backdropKey) private var backdrop = Appearance.Backdrop.aurora.rawValue

    var body: some View {
        LinearGradient(
            colors: (Appearance.Backdrop(rawValue: backdrop) ?? .aurora).colors(dark: colorScheme == .dark),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
