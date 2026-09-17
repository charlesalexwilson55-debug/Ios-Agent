import Photos
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
                    betaBanner
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if shown.isEmpty {
                        ContentUnavailableView(
                            "No pictures yet",
                            systemImage: "photo.on.rectangle",
                            description: Text("Ask Conduit to draw something, or add a photo from the plus "
                                + "menu and ask about it.")
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
            .navigationTitle("Images")
            .fullScreenCover(item: $opened) { image in
                ImageDetailView(id: image.id)
            }
        }
    }

    private var betaBanner: some View {
        HStack(spacing: 10) {
            Text("BETA")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background { Capsule().fill(Color.conduitAccent) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Custom presets for images are coming soon.")
                    .font(.subheadline.weight(.semibold))
                Text("Pictures are drawn by Apple's on-device image model and read by the image model on "
                    + "your phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
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
