import Photos
import PhotosUI
import SwiftUI

/// A picture from `ImageStore`, loaded as a thumbnail. Tapping opens it full
/// screen.
struct StoredImageView: View {
    let id: UUID
    var maxHeight: CGFloat = 260
    var cornerRadius: CGFloat = 16

    @State private var showing = false

    var body: some View {
        Group {
            if let image = ImageStore.shared.thumbnail(id, size: 720) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: maxHeight)
                    .clipShape(.rect(cornerRadius: cornerRadius))
                    .onTapGesture { showing = true }
                    .accessibilityLabel(ImageStore.shared.record(id: id)?.prompt ?? "Picture")
                    .accessibilityAddTraits(.isButton)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.secondary.opacity(0.15))
                    .frame(width: 120, height: 90)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .fullScreenCover(isPresented: $showing) {
            ImageDetailView(id: id)
        }
    }
}

/// The Images page: every picture Conduit made or read.
struct ImagesView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, created, read
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .created: "Created"
            case .read: "Read"
            }
        }
    }

    @State private var store = ImageStore.shared
    @State private var filter: Filter = .all
    @State private var opened: StoredImage?
    @State private var chosenPhotos: [PhotosPickerItem] = []
    @State private var showingCreate = false
    @State private var prompt = ""
    @State private var style: ImageGenerator.Style = .animation
    @State private var generating = false
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 6)]

    private var shown: [StoredImage] {
        switch filter {
        case .all: store.images
        case .created: store.images.filter { $0.kind == .created }
        case .read: store.images.filter { $0.kind == .read }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Create a picture or add one from Photos. Imported pictures get an on-device description.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if shown.isEmpty {
                        ContentUnavailableView(
                            "No pictures yet",
                            systemImage: "photo.on.rectangle",
                            description: Text("Use + to create a picture, or the Photos button to add one.")
                        )
                        .padding(.top, 30)
                    }
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(shown) { image in
                            Button {
                                opened = image
                            } label: {
                                thumbnail(image)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    store.delete(image.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(BackdropView())
            .navigationTitle("Images")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PhotosPicker(selection: $chosenPhotos, maxSelectionCount: 10, matching: .images) {
                        Image(systemName: "photo.badge.plus")
                    }
                    .accessibilityLabel("Import photos")
                    Button { showingCreate = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Create image")
                }
            }
            .onChange(of: chosenPhotos) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        guard let data = try? await item.loadTransferable(type: Data.self),
                              let stored = store.addPhoto(data, prompt: "Imported from Photos") else { continue }
                        if let description = try? await QuickVision.describe(data) {
                            store.setDescription(stored.id, description)
                        }
                    }
                    chosenPhotos = []
                }
            }
            .sheet(isPresented: $showingCreate) { creationSheet }
            .fullScreenCover(item: $opened) { image in
                ImageDetailView(id: image.id)
            }
        }
    }

    private var creationSheet: some View {
        NavigationStack {
            Form {
                Section("Picture") {
                    TextField("What should Conduit draw?", text: $prompt, axis: .vertical)
                        .lineLimit(3...7)
                    Picker("Style", selection: $style) {
                        ForEach(ImageGenerator.Style.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    Button {
                        generate()
                    } label: {
                        HStack {
                            Text("Create image")
                            Spacer()
                            if generating { ProgressView() }
                        }
                    }
                    .disabled(generating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Uses Apple's on-device Image Playground. It needs Apple Intelligence and the model installed in iOS settings.")
                }
            }
            .navigationTitle("Create image")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Done") { showingCreate = false }
            } }
        }
    }

    private func generate() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        generating = true
        error = nil
        Task {
            defer { generating = false }
            do {
                let picture = try await ImageGenerator.create(request, style: style)
                guard store.addCreated(picture, prompt: request, style: style.rawValue) != nil else {
                    error = "Could not save the image."
                    return
                }
                prompt = ""
                showingCreate = false
                filter = .all
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func thumbnail(_ image: StoredImage) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let picture = store.thumbnail(image.id) {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .overlay(alignment: .bottomLeading) {
                Image(systemName: image.kind == .created ? "paintbrush.fill" : "eye.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background { Circle().fill(.black.opacity(0.45)) }
                    .padding(5)
            }
    }
}

/// One picture, full screen, with what was asked and what was seen.
struct ImageDetailView: View {
    let id: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var store = ImageStore.shared
    @State private var saved: String?
    @State private var showInfo = true

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                if let image = store.image(id) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .onTapGesture { withAnimation { showInfo.toggle() } }
                }
                if showInfo, let record = store.record(id: id) {
                    info(record)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let image = store.image(id) {
                        ShareLink(item: Image(uiImage: image),
                                  preview: SharePreview("Picture", image: Image(uiImage: image)))
                        Button {
                            saveToPhotos(image)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel("Save to Photos")
                    }
                    Button(role: .destructive) {
                        store.delete(id)
                        dismiss()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete")
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private func info(_ record: StoredImage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(record.kind == .created ? "Created" : "You asked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(record.prompt)
                    .font(.subheadline)
                if let description = record.description {
                    Text("What the image model saw")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Text(description)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                Text(record.date.formatted(date: .abbreviated, time: .shortened)
                    + (record.style.map { " \u{00B7} \($0.capitalized)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let saved {
                    Text(saved).font(.caption).foregroundStyle(.green)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(12)
    }

    private func saveToPhotos(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in saved = "Allow Conduit to add photos in Settings to save pictures." }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                Task { @MainActor in saved = success ? "Saved to Photos." : "Could not save to Photos." }
            }
        }
    }
}
