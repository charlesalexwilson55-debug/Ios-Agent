import SwiftUI

/// Pages shown in the native bottom tab bar. Settings opens as a sheet.
enum AppPage: String, CaseIterable, Identifiable {
    case chat, libraries, models, settings

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .libraries: "books.vertical"
        case .models: "cpu"
        case .settings: "gearshape"
        }
    }
}
