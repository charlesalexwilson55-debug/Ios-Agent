import SwiftUI
import UIKit

@main
struct ConduitApp: App {
    @State private var catalog = ModelCatalog()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(catalog)
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
    @State private var showingSettings = false
    @State private var menuOpen = false
    /// Views that draw with the chosen accent colour and text size are
    /// rebuilt when either changes.
    @AppStorage(Appearance.accentKey) private var accentHex = ""
    @AppStorage(Appearance.textSizeKey) private var textSize = ""
    @AppStorage(Appearance.backdropKey) private var backdrop = Appearance.Backdrop.aurora.rawValue

    var body: some View {
        ZStack {
            BackdropView()
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
            SidebarOverlay(page: $page, isOpen: $sidebarOpen) {
                showingSettings = true
            }
                .id(appearanceKey)
            if showingSettings {
                settingsWindow
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: page)
        .task {
            // Clear obsolete personality and effort choices from earlier builds.
            UserDefaults.standard.removeObject(forKey: "conduit.personas")
            UserDefaults.standard.removeObject(forKey: "conduit.persona.selected")
            UserDefaults.standard.removeObject(forKey: "conduit.level")
            UserDefaults.standard.removeObject(forKey: "conduit.autoLevel")
            UserDefaults.standard.removeObject(forKey: "conduit.research.plannerModel")
            UserDefaults.standard.removeObject(forKey: "conduit.research.extractorModel")
            let newSession = AgentSession(runner: runner, registry: ToolRegistry.standard())
            newSession.thinkingEnabled = thinking
            newSession.onlineEnabled = online
            newSession.researchEnabled = research
            session = newSession
            Diagnostics.log("app.launch avail=\(Diagnostics.availableMB)MB")
            VolumeKeys.shared.onUp = { selectAdjacentPage(-1) }
            VolumeKeys.shared.onDown = { selectAdjacentPage(1) }
            VolumeKeys.shared.onDoublePress = {
                withAnimation {
                    if showingSettings {
                        showingSettings = false
                        sidebarOpen = true
                    } else {
                        sidebarOpen.toggle()
                    }
                }
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
    }

    /// Chat, with the command bar. A NavigationStack purely to host the
    /// toolbar: without one the toolbar modifier is silently ignored and the
    /// New button never appears. The bar itself is kept hidden so the
    /// transcript runs to the top edge under the glass.
    private var chatPage: some View {
        NavigationStack {
            TranscriptView(
                entries: session?.transcript ?? [],
                accent: Color.conduitAccent,
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
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Circle().fill(Color.blue.gradient)
                            .frame(width: 9, height: 9)
                            .shadow(color: .blue.opacity(0.7), radius: 5)
                        Text(modelStatus)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(modelStatus)
                }
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
                isWorking: session?.isWorking ?? false,
                isModelLoaded: isReady,
                onSend: send,
                onStop: { session?.cancel() }
            )
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
        case .images:
            ImagesView()
        case .models:
            ModelPickerSheet(onSelect: selectFromPage, loadingState: loadingState, showsDoneButton: false)
                .environment(catalog)
        }
    }

    private var appearanceKey: String {
        accentHex + "|" + textSize + "|" + backdrop
    }

    private func selectFromPage(_ model: DiscoveredModel) {
        session?.visionModelDirectory = catalog.visionModels.first?.directory
        select(model)
        page = .chat
    }

    private var isReady: Bool {
        guard case .idle = loadingState else { return false }
        return catalog.selectedModel != nil
    }

    private var modelStatus: String {
        switch loadingState {
        case .loading: "Loading \(catalog.selectedModel?.displayName ?? "model")…"
        case .failed: "Model unavailable"
        case .idle: catalog.selectedModel?.displayName ?? "Choose a model"
        }
    }

    private func selectAdjacentPage(_ offset: Int) {
        guard !showingSettings else { return }
        let pages = AppPage.allCases
        guard let index = pages.firstIndex(of: page) else { return }
        withAnimation { page = pages[(index + offset + pages.count) % pages.count] }
    }

    private var settingsWindow: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.48).ignoresSafeArea()
                    .onTapGesture { showingSettings = false }
                SettingsView(isWorking: session?.isWorking ?? false, canResume: isReady,
                             onOpenChat: { chat in
                                 session?.restore(chat)
                                 draft = ""
                                 page = .chat
                                 showingSettings = false
                             }, onResumeResearch: { run in
                                 session?.resumeResearch(run)
                                 page = .chat
                                 showingSettings = false
                             }, onClose: { showingSettings = false })
                    .frame(width: geometry.size.width - 28, height: geometry.size.height * 0.88)
                    .background(Color.black.opacity(0.7), in: .rect(cornerRadius: 28))
                    .glassEffect(.regular.tint(.black.opacity(0.72)), in: .rect(cornerRadius: 28))
                    .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.15), lineWidth: 0.7) }
                    .clipShape(.rect(cornerRadius: 28))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            }
        }
    }

    private func send() {
        let text = draft
        draft = ""
        session?.submit(text)
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
struct BackdropView: View {
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
