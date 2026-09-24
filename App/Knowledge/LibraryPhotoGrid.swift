import SwiftUI
import UIKit

struct LibraryPhoto: Identifiable, Hashable {
    enum Source: Hashable { case stored(UUID), gallery(String) }
    let source: Source
    var id: String {
        switch source {
        case .stored(let id): "stored:\(id.uuidString)"
        case .gallery(let id): "gallery:\(id)"
        }
    }
}

struct LibraryPhotoGrid: View {
    let libraryID: UUID
    let entries: [TranscriptEntry]
    let isWorking: Bool
    let onAskPhoto: (UUID, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = LibraryStore.shared
    @State private var selectedPhoto: LibraryPhoto?
    @State private var editing = false
    @State private var viewerStartIndex = 0

    private var library: Library? { store.libraries.first { $0.id == libraryID } }

    private var photos: [LibraryPhoto] {
        guard let library else { return [] }
        let local = library.readablePhotoIDs.reversed().map { LibraryPhoto(source: .stored($0)) }
        let gallery = (library.galleryAssetIDs ?? []).map { LibraryPhoto(source: .gallery($0)) }
        return local + gallery
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if photos.isEmpty {
                    ContentUnavailableView("No photos yet", systemImage: "photo.on.rectangle",
                        description: Text("Add photos or import your gallery from Edit library."))
                        .padding(.top, 50)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                        ForEach(photos) { photo in
                            Button {
                                viewerStartIndex = entries.count
                                selectedPhoto = photo
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            } label: {
                                LibraryPhotoThumbnail(photo: photo)
                                    .aspectRatio(1, contentMode: .fill)
                                    .frame(maxWidth: .infinity)
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                }
            }
            .background(BackdropView())
            .navigationTitle(library?.name ?? "Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Back") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit", systemImage: "square.and.pencil") { editing = true }
                }
            }
            .sheet(isPresented: $editing) { LibraryManageView(libraryID: libraryID) }
            .fullScreenCover(item: $selectedPhoto) { photo in
                LibraryPhotoViewer(photo: photo, entries: Array(entries.dropFirst(viewerStartIndex)),
                                   isWorking: isWorking, onAskPhoto: onAskPhoto)
            }
        }
    }
}

private struct LibraryPhotoThumbnail: View {
    let photo: LibraryPhoto
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: photo.id) {
            switch photo.source {
            case .stored(let id): image = ImageStore.shared.thumbnail(id, size: 360)
            case .gallery(let id):
                if let data = await PhotoLibraryIndex.shared.previewData(for: id) {
                    image = UIImage(data: data)
                }
            }
        }
    }
}

private struct LibraryPhotoViewer: View {
    let photo: LibraryPhoto
    let entries: [TranscriptEntry]
    let isWorking: Bool
    let onAskPhoto: (UUID, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var question = ""
    @State private var hideMessages = false
    @State private var isSending = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black, in: .rect(cornerRadius: 24))
                    .clipShape(.rect(cornerRadius: 24))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 55)
            } else {
                ProgressView().tint(.white)
            }
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back to library")
                    Spacer()
                    Button { hideMessages.toggle() } label: {
                        Image(systemName: hideMessages ? "bubble.left" : "bubble.left.slash")
                    }
                    .accessibilityLabel(hideMessages ? "Show messages" : "Hide messages")
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .padding(14)
                .background(.black.opacity(0.45), in: .capsule)
                .padding(.horizontal, 24)
                Spacer(minLength: 0)
                if !hideMessages {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 9) {
                                ForEach(entries.filter { $0.kind == .user || $0.kind == .assistant || $0.kind == .error }) { entry in
                                    Text(entry.text)
                                        .font(.subheadline)
                                        .foregroundStyle(.white)
                                        .padding(11)
                                        .background(entry.kind == .user ? Color.blue.opacity(0.72) : Color.black.opacity(0.76),
                                                    in: .rect(cornerRadius: 15))
                                        .frame(maxWidth: .infinity,
                                               alignment: entry.kind == .user ? .trailing : .leading)
                                        .id(entry.id)
                                }
                                if isWorking { ConduitLoader(color: .blue, status: nil).padding(8) }
                            }
                            .padding(12)
                        }
                        .frame(maxHeight: 300)
                        .onChange(of: entries.last?.text) { _, _ in
                            if let id = entries.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                        }
                    }
                }
                HStack(spacing: 10) {
                    TextField("Ask Conduit about this photo", text: $question, axis: .vertical)
                        .lineLimit(1...3)
                        .foregroundStyle(.black)
                        .tint(.blue)
                        .submitLabel(.send)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(white: 0.83), in: .rect(cornerRadius: 24))
                .padding(.horizontal, 15)
                .padding(.bottom, 12)
            }
        }
        .task(id: photo.id) {
            switch photo.source {
            case .stored(let id): image = ImageStore.shared.image(id)
            case .gallery(let id):
                if let data = await PhotoLibraryIndex.shared.imageData(for: id) { image = UIImage(data: data) }
            }
        }
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        question = ""
        isSending = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            let id: UUID?
            switch photo.source {
            case .stored(let stored): id = stored
            case .gallery(let asset):
                if let data = await PhotoLibraryIndex.shared.imageData(for: asset) {
                    id = ImageStore.shared.addPhoto(data, prompt: text)?.id
                } else { id = nil }
            }
            if let id { onAskPhoto(id, text) }
            isSending = false
        }
    }
}
