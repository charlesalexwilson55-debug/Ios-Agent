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
                downloadSection
                permissionsSection
                capabilitiesSection
            }
            .scrollContentBackground(.hidden)
            .background(BackdropView())
            .navigationTitle("Models")
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
            VStack(spacing: 14) {
                Text("Upload a model")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                Button { isImporting = true } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 32, weight: .light))
                        Text("Choose a model folder or ZIP")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 104)
                    .background(Color.conduitAccent.opacity(0.12), in: .rect(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.conduitAccent.opacity(0.35)) }
                }
                .buttonStyle(.plain)
                .disabled(isCopying)
                if isCopying { ProgressView("Importing model…") }
            }
            .padding(.vertical, 8)

            GeometryReader { geometry in
              ScrollViewReader { reader in
               ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    Button { isImporting = true } label: {
                        VStack(spacing: 9) {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .medium))
                                .frame(width: 54, height: 54)
                                .background(Color.conduitAccent.opacity(0.15), in: .rect(cornerRadius: 16))
                            Text("Add model").font(.caption).lineLimit(1)
                        }
                        .frame(width: 94)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCopying)
                    .accessibilityLabel("Add model")
                    .id("add-model")
                    ForEach(catalog.models) { model in
                        Button { onSelect(model) } label: {
                            VStack(spacing: 9) {
                                Image(systemName: petIcon(for: model))
                                    .font(.system(size: 28))
                                    .frame(width: 54, height: 54)
                                    .background(Color.conduitAccent.opacity(0.15), in: .rect(cornerRadius: 16))
                                Text(model.displayName)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .frame(height: 32, alignment: .top)
                            }
                            .frame(width: 104)
                            .foregroundStyle(catalog.selectedModelID == model.id ? Color.conduitAccent : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete model", systemImage: "trash", role: .destructive) {
                                Task { await catalog.delete(model) }
                            }
                        }
                        .accessibilityLabel("Select \(model.displayName)")
                    }
                }
                .frame(minWidth: geometry.size.width,
                       alignment: catalog.models.isEmpty ? .center : .leading)
                .animation(.spring(response: 0.36, dampingFraction: 0.82), value: catalog.models.count)
               }
               .onAppear { reader.scrollTo("add-model", anchor: .leading) }
              }
            }
            .frame(height: 108)
            if let selected = catalog.selectedModel {
                ModelRow(model: selected, isSelected: true, loadingState: loadingState)
            }
            if !catalog.visionModels.isEmpty {
                Text("Image reader: \(catalog.visionModels.map(\.displayName).joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("On this device")
        } footer: {
            if catalog.isScanning {
                Text("Scanning…")
            }
        }
    }

    private func petIcon(for model: DiscoveredModel) -> String {
        let pets = ["pawprint.fill", "hare.fill", "tortoise.fill", "bird.fill", "fish.fill", "ladybug.fill"]
        let hash = model.displayName.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
        return pets[Int(hash % UInt64(pets.count))]
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
