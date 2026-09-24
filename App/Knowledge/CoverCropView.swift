import SwiftUI
import UIKit

struct CoverCropView: View {
    let image: UIImage
    let onSave: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @State private var lastOffset = CGSize.zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Move and zoom to choose the square cover")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                GeometryReader { geometry in
                    let side = min(geometry.size.width, 340.0)
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .scaleEffect(zoom)
                        .offset(offset)
                        .frame(width: side, height: side)
                        .clipped()
                        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white, lineWidth: 2) }
                        .clipShape(.rect(cornerRadius: 18))
                        .frame(maxWidth: .infinity)
                        .gesture(DragGesture()
                            .onChanged { value in
                                offset = CGSize(width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset })
                }
                .frame(height: 350)
                HStack {
                    Image(systemName: "minus.magnifyingglass")
                    Slider(value: $zoom, in: 1...3)
                    Image(systemName: "plus.magnifyingglass")
                }
                .padding(.horizontal, 24)
                Spacer()
            }
            .padding(.top, 22)
            .navigationTitle("Crop cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let data = crop() { onSave(data); dismiss() }
                    }
                }
            }
        }
    }

    private func crop() -> Data? {
        let normalized = UIGraphicsImageRenderer(size: image.size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let source = normalized.cgImage else { return nil }
        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        let side = min(width, height) / zoom
        let previewSide = min(UIScreen.main.bounds.width - 32, 340)
        let x = min(max((width - side) / 2 - offset.width * side / previewSide, 0), width - side)
        let y = min(max((height - side) / 2 - offset.height * side / previewSide, 0), height - side)
        guard let cropped = source.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.88)
    }
}
