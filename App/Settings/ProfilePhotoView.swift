import SwiftUI
import UIKit

struct ProfilePhotoView: View {
    @AppStorage("conduit.profile.photo") private var photo = Data()
    var size: CGFloat = 48
    var body: some View {
        Group {
            if let image = UIImage(data: photo) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                    .foregroundStyle(Color.conduitAccent)
            }
        }.frame(width: size, height: size).clipShape(.circle)
    }
}
