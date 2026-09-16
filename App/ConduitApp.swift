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
        }
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
    @State private var showingModelPicker = false
    @State private var loadingState: ModelLoadingState = .idle
    /// Persisted so the choice survives relaunches. On by default: correct
    /// answers to maths and code matter more than speed on those questions.
    @AppStorage("conduit.thinking") private var thinking = true
    @AppStorage("conduit.online") private var online = true
    @State private var page: AppPage = .chat
    @State private var sidebarOpen = false

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
        }
        .animation(.easeInOut(duration: 0.2), value: page)
        .sheet(isPresented: $showingModelPicker) {
            ModelPickerSheet(onSelect: select, loadingState: loadingState)
                .environment(catalog)
        }
        .task {
            let newSession = AgentSession(runner: runner, registry: ToolRegistry.standard())
            newSession.thinkingEnabled = thinking
            newSession.onlineEnabled = online
            session = newSession
            Diagnostics.log("app.launch avail=\(Diagnostics.availableMB)MB")

            // Read before loading, which writes a marker of its own.
            let unfinished = Diagnostics.takeUnfinishedWork()
            if let unfinished {
                Diagnostics.log("app.previous-run-died-during \(unfinished)")
                newSession.noteInterruptedWork(unfinished)
            }
            let diedWhileLoading = unfinished?.hasPrefix("load") ?? false

            await catalog.refresh()
            // Reload whatever was in use last launch, so the app comes back
            // ready rather than making the user pick again every time. Not if
            // loading it is what killed the last run: that would crash again
            // on every launch.
            if let previous = catalog.selectedModel, !diedWhileLoading {
                await load(previous)
            } else {
                showingModelPicker = true
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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: consumePendingTask()
            case .inactive, .background: session?.leavingForeground()
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
            TranscriptView(entries: session?.transcript ?? [])
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
                modelLabel: catalog.selectedModel?.displayName ?? "Model",
                isWorking: session?.isWorking ?? false,
                isModelLoaded: isReady,
                onSend: send,
                onStop: { session?.cancel() },
                onPickModel: { showingModelPicker = true }
            )
        }
    }

    @ViewBuilder
    private var otherPage: some View {
        switch page {
        case .chat:
            EmptyView()
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
        }
    }

    private func selectFromPage(_ model: DiscoveredModel) {
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
        showingModelPicker = false
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
            // Surfaced in the picker rather than as an alert: the fix is
            // almost always picking a different, smaller model, and that is
            // where the user does it.
            showingModelPicker = true
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

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.05, green: 0.06, blue: 0.11),
                   Color(red: 0.10, green: 0.08, blue: 0.16),
                   Color(red: 0.04, green: 0.07, blue: 0.10)]
                : [Color(red: 0.93, green: 0.95, blue: 1.00),
                   Color(red: 0.97, green: 0.94, blue: 0.99),
                   Color(red: 0.91, green: 0.96, blue: 0.97)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
