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
                        ModelSelectionWheel(models: catalog.models, selectedID: catalog.selectedModelID, onSelect: onSelect,
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
                            HStack(spacing: 8) {
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

/// Drag rotates the wheel; the model loads only after the wheel settles.
private struct ModelSelectionWheel: View {
    let models: [DiscoveredModel]
    let selectedID: String?
    let onSelect: (DiscoveredModel) -> Void
    let onDelete: (DiscoveredModel) -> Void
    @State private var rotation = 0.0
    @State private var lastAngle: Double?
    @State private var dragging = false
    private var step: Double { 360 / Double(max(models.count, 1)) }
    private var focus: Int { ModelWheel.index(rotation: rotation, count: models.count) ?? 0 }
    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                let radius = max(70, size / 2 - 34)
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 1).frame(width: radius * 2, height: radius * 2)
                    ModelBrandIcon(model: models[focus]).frame(width: 78, height: 78)
                    if models.count > 1 {
                        ForEach(Array(models.indices), id: \.self) { index in
                            let model = models[index]
                            let angle = (Double(index) * step + rotation - 90) * .pi / 180
                            Button { settle(at: index) } label: {
                                ModelBrandIcon(model: model).padding(8).frame(width: 54, height: 54)
                                    .background(.black.opacity(0.6), in: .circle)
                                    .overlay { Circle().strokeBorder(index == focus ? Color.conduitAccent : .white.opacity(0.12), lineWidth: index == focus ? 2 : 1) }
                            }.buttonStyle(.plain)
                            .position(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
                            .accessibilityLabel("Select \(model.displayName)")
                            .contextMenu { Button("Delete model", systemImage: "trash", role: .destructive) { onDelete(model) } }
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(.circle)
                .gesture(DragGesture(minimumDistance: 6).onChanged { value in
                    guard models.count > 1 else { return }
                    dragging = true
                    let angle = atan2(Double(value.location.y - center.y), Double(value.location.x - center.x)) * 180 / .pi
                    let previous = lastAngle ?? atan2(Double(value.startLocation.y - center.y), Double(value.startLocation.x - center.x)) * 180 / .pi
                    var delta = angle - previous
                    if delta > 180 { delta -= 360 }; if delta < -180 { delta += 360 }
                    rotation += delta; lastAngle = angle
                }.onEnded { _ in
                    lastAngle = nil; dragging = false
                    let selected = focus
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { rotation = (rotation / step).rounded() * step }
                    choose(selected)
                })
            }.frame(height: 275)
            Text(models[focus].displayName).font(.headline).multilineTextAlignment(.center).lineLimit(3)
                .frame(maxWidth: .infinity).padding(.horizontal, 16)
        }
        .onAppear { align() }
        .onChange(of: selectedID) { _, _ in if !dragging { align() } }
        .onChange(of: models.map(\.id)) { _, _ in align() }
        .accessibilityElement(children: .contain).accessibilityLabel("Model wheel").accessibilityValue(models[focus].displayName)
        .accessibilityAdjustableAction { direction in settle(at: (focus + (direction == .increment ? 1 : models.count - 1)) % models.count) }
    }
    private func align() { rotation = -Double(models.firstIndex { $0.id == selectedID } ?? 0) * step }
    private func settle(at index: Int) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { rotation = -Double(index) * step }
        choose(index)
    }
    private func choose(_ index: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        if models[index].id != selectedID { onSelect(models[index]) }
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
