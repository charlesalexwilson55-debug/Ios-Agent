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
    @AppStorage(ConduitLiveStatus.enabledKey) private var liveActivityEnabled = true
    @AppStorage(InferencePolicy.batterySaverKey) private var batterySaver = false
    @AppStorage(InferencePolicy.batteryModelKey) private var batteryModel = ""
    @AppStorage("conduit.power.preSaverModel") private var preSaverModel = ""
    @AppStorage("conduit.power.autoModel") private var autoModel = ""
    /// Research mode. Not persisted: it changes what every message does, so
    /// it starts off each launch.
    @State private var research = false
    @State private var page: AppPage = .chat
    @State private var showingSettings = false
    @State private var menuOpen = false
    @State private var startupReady = false
    @State private var startupVisible = true
    /// Views that draw with the chosen accent colour and text size are
    /// rebuilt when either changes.
    @AppStorage(Appearance.accentKey) private var accentHex = ""
    @AppStorage(ModelColors.storageKey) private var modelColors = ""
    @AppStorage(Appearance.textSizeKey) private var textSize = ""
    @AppStorage(Appearance.backdropKey) private var backdrop = Appearance.Backdrop.aurora.rawValue
    @AppStorage(Appearance.startupEnabledKey) private var startupEnabled = true
    @AppStorage(Appearance.startupOrbKey) private var startupOrbHex = AccentPalette.palette[0].hex

    var body: some View {
        VStack(spacing: 0) {
        ZStack {
            chatPage
                .opacity(page == .chat ? 1 : 0)
                .allowsHitTesting(page == .chat)
                .accessibilityHidden(page != .chat)
            if page == .libraries {
                LibrariesView(onAskPhoto: { id, question in
                    session?.submit(question, libraryPhotoID: id)
                }, entries: session?.transcript ?? [], isWorking: session?.isWorking ?? false)
            }
            if page == .models {
                ModelPickerSheet(onSelect: selectFromPage, loadingState: loadingState,
                                 showsDoneButton: false)
                    .environment(catalog)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
            // The transcript has a physical boundary above the footer rather
            // than relying on safe-area insets during keyboard and row changes.
            VStack(spacing: 4) {
                if page == .chat {
                    GlassCommandBar(
                        draft: $draft,
                        thinking: $thinking,
                        online: $online,
                        research: $research,
                        menuOpen: $menuOpen,
                        isWorking: session?.isWorking ?? false,
                        isModelLoaded: isReady,
                        onSend: send,
                        onStop: { session?.cancel() },
                        onNewConversation: { session?.clear() }
                    )
                    .zIndex(1)
                }
                ConduitNavigationBar(selected: $page, onSettings: { showingSettings = true })
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .zIndex(1)
        }
        .background(BackdropView())
        .overlay {
            if startupEnabled && startupVisible {
                StartupSplash(ready: startupReady,
                              color: Color(hex: startupOrbHex) ?? .blue,
                              onComplete: { withAnimation(.easeOut(duration: 0.28)) { startupVisible = false } })
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .tint(Color.conduitAccent)
        .sheet(isPresented: $showingSettings) { settingsSheet }
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
            UIDevice.current.isBatteryMonitoringEnabled = true
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            Diagnostics.log("app.launch build=\(build) avail=\(Diagnostics.availableMB)MB")
            // Read before loading, which writes a marker of its own.
            let unfinished = Diagnostics.takeUnfinishedWork()
            if let unfinished {
                Diagnostics.log("app.previous-run-died-during \(unfinished)")
                newSession.noteInterruptedWork(unfinished)
            }
            let diedWhileLoading = unfinished?.hasPrefix("load") ?? false

            await catalog.refresh()
            updateSpecialists()
            // Reload whatever was in use last launch, so the app comes back
            // ready rather than making the user pick again every time. Not if
            // loading it is what killed the last run: that would crash again
            // on every launch.
            if let previous = catalog.selectedModel, !diedWhileLoading {
                await load(previous)
            } else {
                page = .models
            }
            checkBatterySaver()
            consumePendingTask()
            startupReady = true
            if !startupEnabled { startupVisible = false }
            consumeEdge0DownloadRequest()
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
        .onChange(of: catalog.visionModels) { _, _ in updateSpecialists() }
        .onChange(of: catalog.models) { _, _ in updateSpecialists() }
        .onChange(of: page) { _, _ in updateSpecialists() }
        .onChange(of: session?.isWorking) { _, working in if working == true { updateSpecialists() } }
        .onChange(of: session?.isWorking) { _, working in
            ConduitLiveStatus.shared.setWorking(working == true, foreground: scenePhase == .active,
                status: research ? "Researching" : (thinking ? "Thinking" : "Working"))
            if working == false { checkBatterySaver() }
        }
        .onChange(of: liveActivityEnabled) { _, _ in
            ConduitLiveStatus.shared.setWorking(session?.isWorking == true, foreground: scenePhase == .active,
                status: research ? "Researching" : "Working")
        }
        .onChange(of: batterySaver) { _, _ in checkBatterySaver() }
        .onChange(of: batteryModel) { _, _ in checkBatterySaver() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            checkBatterySaver()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            checkBatterySaver()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                ConduitLiveStatus.shared.setWorking(session?.isWorking == true, foreground: true,
                    status: research ? "Researching" : "Working")
                consumePendingTask()
                checkBatterySaver()
                consumeEdge0DownloadRequest()
            case .inactive, .background:
                ConduitLiveStatus.shared.pause()
                session?.leavingForeground()
            default: break
            }
        }
    }

    /// The transcript occupies the full chat viewport without a navigation header.
    private var chatPage: some View {
        TranscriptView(
            entries: session?.transcript ?? [],
            accent: Color(hex: ModelColors.hex(for: catalog.selectedModelID, in: modelColors)) ?? .blue,
            onCancelActivity: { id, entryID in session?.cancelActivity(id, in: entryID) },
            isWorking: session?.isWorking ?? false,
            onSelectResearchCandidate: { id, entryID in session?.selectResearchCandidate(id, in: entryID) },
            onRejectResearchCandidate: { id, entryID in session?.rejectResearchCandidate(id, in: entryID) }
        )
        .overlay {
            if menuOpen {
                Color.black.opacity(0.06)
                    .contentShape(.rect)
                    .onTapGesture { menuOpen = false }
                    .accessibilityHidden(true)
            }
        }
        .id(appearanceKey)
        .onChange(of: page) { _, _ in menuOpen = false }
    }

    private var appearanceKey: String {
        accentHex + "|" + textSize + "|" + backdrop
    }

    /// A one-shot request placed through this app's USB document sharing container.
    /// It contains only a supported tier, never an arbitrary URL or executable command.
    private func consumeEdge0DownloadRequest() {
        guard session != nil, !Edge0Download.shared.isRunning else { return }
        let url = ModelCatalog.documentsRoot.appendingPathComponent("edge0-download-request.json")
        guard let data = try? Data(contentsOf: url),
              let request = try? JSONDecoder().decode([String: String].self, from: data),
              let name = request["tier"], let tier = Edge0Download.Tier(rawValue: name) else { return }
        try? FileManager.default.removeItem(at: url)
        page = .models
        Edge0Download.shared.start(tier, catalog: catalog)
    }

    private func selectFromPage(_ model: DiscoveredModel) {
        preSaverModel = ""
        autoModel = ""
        updateSpecialists()
        select(model)
    }

    private func updateSpecialists() {
        session?.visionModelDirectory = catalog.preferredVisionModel?.directory
        func configuration(_ role: ModelTaskRouter.Role) -> ModelRunner.Configuration? {
            guard let model = catalog.specialist(role) else { return nil }
            return .init(directory: model.directory, name: model.displayName, adapter: nil)
        }
        session?.quickTextModel = configuration(.quickText)
        session?.researchCheckModel = configuration(.researchCheck)
        session?.heavyTaskModel = configuration(.heavy)
    }

    private var isReady: Bool {
        guard case .idle = loadingState else { return false }
        return catalog.selectedModel != nil
    }

    private var settingsSheet: some View {
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
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
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

    private func checkBatterySaver() {
        guard scenePhase == .active, session?.isWorking != true,
              case .idle = loadingState else { return }
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return }
        if !batterySaver || level >= 0.25 {
            guard !preSaverModel.isEmpty, catalog.selectedModelID == autoModel,
                  let previous = catalog.models.first(where: { $0.id == preSaverModel }) else {
                preSaverModel = ""
                autoModel = ""
                return
            }
            preSaverModel = ""
            autoModel = ""
            select(previous)
            return
        }
        guard level <= 0.20, let current = catalog.selectedModel,
              current.id != autoModel else { return }
        let smaller = catalog.models.filter {
            $0.id != current.id && $0.sizeBytes < current.sizeBytes && ($0.quantBits ?? 4) <= 4
        }.sorted { $0.sizeBytes < $1.sizeBytes }
        let chosen = smaller.first(where: { $0.id == batteryModel }) ?? smaller.first
        guard let chosen else { return }
        preSaverModel = current.id
        autoModel = chosen.id
        select(chosen)
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
            checkBatterySaver()
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
