import SwiftUI
import UIKit

struct ChatAttachments: View {
    @Binding var data: [Data]
    var isLoading: Bool
    var error: String?
    var body: some View {
        if !data.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(data.indices, id: \.self) { index in
                        if let image = UIImage(data: data[index]) {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: 62, height: 62).clipShape(.rect(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    Button { if data.indices.contains(index) { data.remove(at: index) } } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black)
                                    }.accessibilityLabel("Remove attached image")
                                }
                        }
                    }
                }.padding(.horizontal, 18)
            }
        }
        if isLoading { ProgressView("Loading images…").font(.caption) }
        if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
}
