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
    /// Views that draw with the chosen accent colour and text size are
    /// rebuilt when either changes.
    @AppStorage(Appearance.accentKey) private var accentHex = ""
    @AppStorage(ModelColors.storageKey) private var modelColors = ""
    @AppStorage(Appearance.textSizeKey) private var textSize = ""
    @AppStorage(Appearance.backdropKey) private var backdrop = Appearance.Backdrop.aurora.rawValue

    var body: some View {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConduitNavigationBar(selected: $page, onSettings: { showingSettings = true })
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
            Diagnostics.log("app.launch avail=\(Diagnostics.availableMB)MB")
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
            checkBatterySaver()
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
        .onChange(of: catalog.visionModels) { _, models in
            session?.visionModelDirectory = models.first?.directory
        }
        .onChange(of: session?.isWorking) { _, working in
            if working == false { checkBatterySaver() }
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
                consumePendingTask()
                checkBatterySaver()
            case .inactive, .background:
                session?.leavingForeground()
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
                accent: Color(hex: ModelColors.hex(for: catalog.selectedModelID, in: modelColors)) ?? .blue,
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
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.32), in: .capsule)
                    .overlay { Capsule().strokeBorder(.white.opacity(0.86), lineWidth: 0.8) }
                    .shadow(color: .blue.opacity(0.65), radius: 10)
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

    private var appearanceKey: String {
        accentHex + "|" + textSize + "|" + backdrop
    }

    private func selectFromPage(_ model: DiscoveredModel) {
        preSaverModel = ""
        autoModel = ""
        session?.visionModelDirectory = catalog.visionModels.first?.directory
        select(model)
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
