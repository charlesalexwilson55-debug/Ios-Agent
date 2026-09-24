import Foundation
import SwiftUI

enum ModelColors {
    static let storageKey = "conduit.models.colors"

    static func hex(for id: String?, in stored: String) -> String {
        guard let id,
              let data = stored.data(using: .utf8),
              let colors = try? JSONDecoder().decode([String: String].self, from: data) else {
            return AccentPalette.palette[0].hex
        }
        return colors[id] ?? AccentPalette.palette[0].hex
    }

    static func setting(_ hex: String, for id: String, in stored: String) -> String {
        let colors = (stored.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
        var updated = colors
        updated[id] = hex
        guard let data = try? JSONEncoder().encode(updated),
              let result = String(data: data, encoding: .utf8) else { return stored }
        return result
    }
}
