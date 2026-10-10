import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ModelPickerSheet: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    let onSelect: (DiscoveredModel) -> Void
    let loadingState: ModelLoadingState
    var showsDoneButton = true
    @State private var importing = false
    @State private var copying = false
    @State private var information = false
    @State private var importError: String?
    @AppStorage(ModelColors.storageKey) private var modelColors = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    HStack(spacing: 8) {
                        Text("Upload a model").font(.title2.bold())
                        Button { information = true } label: { Image(systemName: "info.circle").font(.subheadline) }
                            .accessibilityLabel("Model import help")
                    }.padding(.top, 12)
                    Button { importing = true } label: {
                        Image(systemName: "folder.badge.plus").font(.system(size: 36, weight: .light))
                            .frame(maxWidth: .infinity, minHeight: 100)
                            .glassEffect(.regular.tint(.black.opacity(0.2)), in: .rect(cornerRadius: 24))
                    }
                    .buttonStyle(.plain).disabled(copying).accessibilityLabel("Import model folder or ZIP")
                    if copying { ProgressView("Importing…") }
                    if !catalog.models.isEmpty {
                        ModelSelectionCarousel(models: catalog.models, selectedID: catalog.selectedModelID, onSelect: onSelect,
                                            onDelete: { model in Task { await catalog.delete(model) } })
                        if let selected = catalog.selectedModel {
                            Text(selected.sizeDescription).font(.caption).foregroundStyle(.secondary)
                            switch loadingState {
                            case .loading(let status): ProgressView(status).font(.caption)
                            case .failed(let reason): Text(reason).font(.caption).foregroundStyle(.red)
                            case .idle: EmptyView()
                            }
                            if let warning = selected.memoryWarning {
                                Text(warning).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 4) {
                                ForEach(AccentPalette.palette) { swatch in
                                    Button {
                                        modelColors = ModelColors.setting(swatch.hex, for: selected.id, in: modelColors)
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        Circle().fill(Color(hex: swatch.hex) ?? .blue).frame(width: 23, height: 23)
                                            .overlay { Circle().strokeBorder(.white, lineWidth: ModelColors.hex(for: selected.id, in: modelColors) == swatch.hex ? 2 : 0) }
                                    }.buttonStyle(.plain).frame(minWidth: 32, minHeight: 40).accessibilityLabel(swatch.name)
                                }
                            }
                            ConduitLoader(color: Color(hex: ModelColors.hex(for: selected.id, in: modelColors)) ?? .blue, status: nil)
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 30)
            }
            .background(BackdropView()).toolbar(.hidden, for: .navigationBar)
            .task { await catalog.refresh() }.refreshable { await catalog.refresh() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .folder]) { result in
                switch result {
                case .success(let url):
                    Task {
                        copying = true
                        defer { copying = false }
                        do { try await catalog.importModel(from: url) }
                        catch { importError = error.localizedDescription }
                    }
                case .failure(let error): importError = error.localizedDescription
                }
            }
            .sheet(isPresented: $information) {
                NavigationStack {
                    ModelRoutingSettings().navigationTitle("Models").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { information = false } } }
                }
            }
            .alert("Could not import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            } message: { Text(importError ?? "") }
            .overlay(alignment: .topTrailing) {
                if showsDoneButton { Button("Done") { dismiss() }.padding(12) }
            }
        }
    }
}

/// Three visible slots keep the next swipe discoverable in either direction.
private struct ModelSelectionCarousel: View {
    let models: [DiscoveredModel]
    let selectedID: String?
    let onSelect: (DiscoveredModel) -> Void
    let onDelete: (DiscoveredModel) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0
    @State private var settling = false
    private var focus: Int { models.firstIndex { $0.id == selectedID } ?? 0 }

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geometry in
                let stride = geometry.size.width / 2 + 12
                ZStack {
                    ForEach(models.isEmpty ? [] : models.count > 1 ? Array(-2...2) : [0], id: \.self) { slot in
                        let model = models[CarouselIndex.wrapped(focus + slot, count: models.count)]
                        VStack(spacing: 24) {
                            ModelBrandIcon(model: model).frame(width: 104, height: 104)
                            Text(model.displayName).font(.title3.weight(.semibold))
                                .multilineTextAlignment(.center).lineLimit(3)
                        }
                        .frame(width: stride - 12, height: 230)
                        .scaleEffect(slot == 0 ? 1 : 0.82)
                        .opacity(slot == 0 ? 1 : 0.55)
                        .offset(x: CGFloat(slot) * stride + drag)
                        .accessibilityHidden(slot != 0)
                        .contextMenu {
                            Button("Delete model", systemImage: "trash", role: .destructive) { onDelete(model) }
                        }
                    }
                }.frame(width: geometry.size.width, height: 230).clipped()
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        guard models.count > 1, !settling,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        drag = max(-stride, min(stride, value.translation.width))
                    }
                    .onEnded { value in
                        guard models.count > 1, !settling else { return }
                        let horizontal = abs(value.translation.width) > abs(value.translation.height)
                        let direction = horizontal && abs(value.predictedEndTranslation.width) > stride * 0.22
                            ? (value.translation.width < 0 ? 1 : -1) : 0
                        settle(direction, stride: stride)
                    })
            }.frame(height: 230)
            if models.count > 1 { Text("Swipe to change model").font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Model carousel")
        .accessibilityAdjustableAction { direction in
            guard models.count > 1, !settling else { return }
            select(direction == .increment ? 1 : -1)
        }
        .onChange(of: models.map(\.id)) { _, _ in drag = 0; settling = false }
    }

    private func select(_ direction: Int) {
        guard !models.isEmpty else { return }
        let model = models[CarouselIndex.wrapped(focus + direction, count: models.count)]
        guard model.id != selectedID else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        onSelect(model)
    }

    private func settle(_ direction: Int, stride: CGFloat) {
        settling = true
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20), completionCriteria: .logicallyComplete) {
            drag = -CGFloat(direction) * stride
        } completion: {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { select(direction); drag = 0; settling = false }
        }
    }
}

private struct ModelBrandIcon: View {
    let model: DiscoveredModel
    private var asset: String? {
        let name = model.displayName.lowercased()
        if name.contains("qwen") { return "ModelBrandQwen" }
        if name.contains("minicpm") { return "ModelBrandMiniCPM" }
        if name.contains("edge0") { return "ModelBrandEdge0" }
        return nil
    }
    var body: some View {
        Group {
            if let asset { Image(asset).resizable().scaledToFit() }
            else { Text(String(model.displayName.prefix(2)).uppercased()).font(.title2.bold()).foregroundStyle(Color.conduitAccent) }
        }.clipShape(.rect(cornerRadius: 12))
    }
}

struct ModelRoutingSettings: View {
    @Environment(ModelCatalog.self) private var catalog
    @AppStorage(ModelTaskRouter.enabledKey) private var automatic = true
    @AppStorage("conduit.models.route.researchCheck") private var research = ""
    @AppStorage("conduit.models.route.quickText") private var quick = ""
    @AppStorage("conduit.models.route.heavy") private var heavy = ""
    @AppStorage("conduit.models.route.vision") private var vision = ""
    var body: some View {
        Form {
            Section { Text("Import an MLX model folder or ZIP containing its weights, config and tokenizer. Conduit copies models from Files and does not download them.") }
            Section("Routing") {
                Toggle("Choose models by task", isOn: $automatic)
                if automatic {
                    route("Quick text", $quick, catalog.models)
                    route("Research checks", $research, catalog.models)
                    route("Heavy code", $heavy, catalog.models)
                }
                route("Image reading", $vision, catalog.visionModels)
            }
            if !catalog.adapters.isEmpty {
                Section("Adapter") {
                    Picker("LoRA adapter", selection: Binding(get: { catalog.selectedAdapterID ?? "" }, set: { catalog.select(adapterID: $0.isEmpty ? nil : $0) })) {
                        Text("None").tag("")
                        ForEach(catalog.adapters) { Text($0.displayName).tag($0.id) }
                    }
                }
            }
        }.scrollContentBackground(.hidden).background(BackdropView())
    }
    private func route(_ name: String, _ selection: Binding<String>, _ models: [DiscoveredModel]) -> some View {
        Picker(name, selection: selection) {
            Text("Automatic").tag(""); Text("Use default").tag("none")
            ForEach(models) { Text($0.displayName).tag($0.id) }
        }
    }
}

enum ModelLoadingState: Equatable { case idle, loading(String), failed(String) }
