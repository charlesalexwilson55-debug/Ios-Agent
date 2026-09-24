import SwiftUI
import UIKit
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
    @State private var showingSuggestions = false
    @State private var isCopying = false
    @State private var importError: String?
    @AppStorage(ModelColors.storageKey) private var modelColors = ""

    var body: some View {
        NavigationStack {
            List {
                modelsSection
                if !catalog.adapters.isEmpty { adaptersSection }
            }
            .scrollContentBackground(.hidden)
            .background(BackdropView())
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .refreshable { await catalog.refresh() }
            .task {
                await catalog.refresh()
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
            .sheet(isPresented: $showingSuggestions) {
                NavigationStack {
                    List { downloadSection }
                        .navigationTitle("Suggested models")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSuggestions = false }
                            }
                        }
                }
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
                HStack(spacing: 7) {
                    Text("Upload a model").font(.title2.bold())
                    Button { showingSuggestions = true } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Suggested models")
                }
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

            if !catalog.models.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    if catalog.models.count > 1 {
                        modelTile(offset: -1)
                    }
                    modelTile(offset: 0)
                    if catalog.models.count > 2 {
                        modelTile(offset: 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Model carousel")
            }
            if let selected = catalog.selectedModel {
                ModelRow(model: selected, isSelected: true, loadingState: loadingState)
                Text("Conduit light")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .center)
                HStack(spacing: 12) {
                    ForEach(AccentPalette.palette) { swatch in
                        Button {
                            modelColors = ModelColors.setting(swatch.hex, for: selected.id, in: modelColors)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Circle()
                                .fill(Color(hex: swatch.hex) ?? .blue)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle().strokeBorder(.white, lineWidth:
                                        ModelColors.hex(for: selected.id, in: modelColors) == swatch.hex ? 2 : 0)
                                }
                        }
                        .accessibilityLabel("\(swatch.name) model light")
                    }
                }
                .frame(maxWidth: .infinity)
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

    private func modelTile(offset: Int) -> some View {
        let selectedIndex = catalog.models.firstIndex { $0.id == catalog.selectedModelID } ?? 0
        let index = (selectedIndex + offset + catalog.models.count) % catalog.models.count
        let model = catalog.models[index]
        let isCenter = offset == 0
        return Button { onSelect(model); UISelectionFeedbackGenerator().selectionChanged() } label: {
            VStack(spacing: 10) {
                Image(systemName: petIcon(for: model))
                    .font(.system(size: isCenter ? 44 : 26))
                    .frame(width: isCenter ? 90 : 64, height: isCenter ? 90 : 64)
                    .background(Color(hex: ModelColors.hex(for: model.id, in: modelColors))?.opacity(0.18) ?? .blue.opacity(0.18),
                                in: .rect(cornerRadius: 24))
                Text(model.displayName)
                    .font(isCenter ? .headline : .caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: isCenter ? 150 : 95)
            .foregroundStyle(isCenter ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete model", systemImage: "trash", role: .destructive) {
                Task { await catalog.delete(model) }
            }
        }
        .accessibilityLabel("Select \(model.displayName)")
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
