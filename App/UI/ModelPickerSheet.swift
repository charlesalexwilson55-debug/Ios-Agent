import SwiftUI
import UniformTypeIdentifiers

/// Model selection, import and download.
///
/// Importing from the Files app is presented first and downloading second,
/// which is the opposite of what most apps do. The reason is bandwidth: these
/// are 2-5GB files, and a user who already has the weights on a computer
/// should not be nudged into pulling them again over cellular.
struct ModelPickerSheet: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    let onSelect: (DiscoveredModel) -> Void
    let loadingState: ModelLoadingState
    /// Off when shown as a full page from the sidebar, where there is no
    /// sheet to dismiss.
    var showsDoneButton = true

    @State private var isImporting = false
    @State private var isCopying = false
    @State private var importError: String?
    @State private var permissionSnapshot: Permissions.Snapshot?

    var body: some View {
        NavigationStack {
            List {
                modelsSection
                if !catalog.adapters.isEmpty { adaptersSection }
                importSection
                downloadSection
                permissionsSection
                capabilitiesSection
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isImporting = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Import model")
                        .disabled(isCopying)
                }
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .refreshable { await catalog.refresh() }
            .task {
                await catalog.refresh()
                permissionSnapshot = await Permissions.shared.snapshot()
            }
            .fileImporter(
                isPresented: $isImporting,
                // A model is a folder of weights plus config and tokenizer
                // files, so the picker selects a directory, not a file.
                allowedContentTypes: [.zip, .folder],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            // A real two-way binding, not `.constant`: with a constant binding
            // SwiftUI cannot clear the flag itself, so an interactive dismiss
            // leaves the state set and the alert immediately re-presents.
            .alert("Could not import", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        Section {
            if catalog.models.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No models on this device")
                        .font(.system(size: 15, weight: .medium))
                    Text("Add one below by importing a folder or downloading.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            ForEach(catalog.models) { model in
                Button {
                    onSelect(model)
                } label: {
                    ModelRow(
                        model: model,
                        isSelected: catalog.selectedModelID == model.id,
                        loadingState: loadingState
                    )
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await catalog.delete(model) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("On this device")
        } footer: {
            if catalog.isScanning {
                Text("Scanning…")
            }
        }
    }

    private var adaptersSection: some View {
        Section {
            // "None" is an explicit row rather than a swipe-to-clear, because
            // an adapter silently changing the model's behaviour is exactly
            // the kind of state a user needs to be able to see and turn off.
            Button {
                catalog.select(adapterID: nil)
            } label: {
                HStack {
                    Text("None")
                    Spacer()
                    if catalog.selectedAdapterID == nil {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)

            ForEach(catalog.adapters) { adapter in
                Button {
                    catalog.select(adapterID: adapter.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(adapter.displayName)
                            Text(adapter.sizeDescription)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if catalog.selectedAdapterID == adapter.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("LoRA adapter")
        } footer: {
            Text("An adapter fine-tunes the selected model's behaviour without replacing its "
                + "weights. Reselect the model after changing this.")
        }
    }

    // MARK: - Adding

    private var importSection: some View {
        Section {
            Button {
                isImporting = true
            } label: {
                Label("Add model file or folder", systemImage: "plus.circle")
            }
            .disabled(isCopying)
            if isCopying { ProgressView("Importing model…") }
        } footer: {
            Text("Press + and choose a ZIP of the complete MLX model, or its folder. Keep the config, tokenizer and all weight files together.")
        }
    }

    private var downloadSection: some View {
        Section {
            ForEach(ModelCatalog.suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(suggestion.displayName)
                            .font(.system(size: 15, weight: .medium))
                        Spacer()
                        Text(ByteCountFormatter.string(
                            fromByteCount: suggestion.approxBytes, countStyle: .file
                        ))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    }
                    Text(suggestion.note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(suggestion.repoID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 3)
            }
        } header: {
            Text("Suggested")
        } footer: {
            Text("Download these with the MLX or Hugging Face CLI on a computer, then import the "
                + "folder. Pulling several gigabytes through the app is slower and more fragile "
                + "than copying it across.")
        }
    }

    // MARK: - Status

    private var permissionsSection: some View {
        Section {
            if let snapshot = permissionSnapshot {
                PermissionRow(name: "Calendar", status: snapshot.calendar)
                PermissionRow(name: "Reminders", status: snapshot.reminders)
                PermissionRow(name: "Contacts", status: snapshot.contacts)
                PermissionRow(name: "Notifications", status: snapshot.notifications)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Conduit asks for each of these the first time it needs them. Denied permissions "
                + "can only be changed in the Settings app.")
        }
    }

    private var capabilitiesSection: some View {
        Section {
            NavigationLink {
                CapabilitiesView()
            } label: {
                Label("What Conduit can and cannot do", systemImage: "info.circle")
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                isCopying = true
                defer { isCopying = false }
                do {
                    try await catalog.importModel(from: url)
                } catch {
                    importError = error.localizedDescription
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

/// Load progress, surfaced so a 40-second model load does not look like a hang.
enum ModelLoadingState: Equatable {
    case idle
    case loading(String)
    case failed(String)
}

private struct ModelRow: View {
    let model: DiscoveredModel
    let isSelected: Bool
    let loadingState: ModelLoadingState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(model.sizeDescription)
                        if let architecture = model.architecture {
                            Text("·")
                            Text(architecture)
                        }
                        if let bits = model.quantBits {
                            Text("·")
                            Text("\(bits)-bit")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoadingThis {
                    ProgressView().controlSize(.small)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }

            if let warning = model.memoryWarning {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 1)
            }

            if case .failed(let message) = loadingState, isSelected {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 3)
    }

    private var isLoadingThis: Bool {
        if case .loading(let id) = loadingState { return id == model.id }
        return false
    }
}

private struct PermissionRow: View {
    let name: String
    let status: String

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(status)
                .font(.system(size: 13))
                .foregroundStyle(status.hasPrefix("Denied") ? .red : .secondary)
        }
    }
}
