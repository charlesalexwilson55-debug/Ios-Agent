import SwiftUI
import UIKit

enum AccentPalette {
    struct Swatch: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let palette: [Swatch] = [
        Swatch(name: "Blue", hex: "#0A84FF"),
        Swatch(name: "Purple", hex: "#8E5CF7"),
        Swatch(name: "Pink", hex: "#FF4F9A"),
        Swatch(name: "Red", hex: "#FF453A"),
        Swatch(name: "Orange", hex: "#FF9F0A"),
        Swatch(name: "Yellow", hex: "#FFD60A"),
        Swatch(name: "Green", hex: "#30D158"),
        Swatch(name: "Teal", hex: "#40C8E0"),
        Swatch(name: "Brown", hex: "#AC8E68"),
        Swatch(name: "Graphite", hex: "#636366"),
    ]

}

extension Color {
    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// "#RRGGBB" in sRGB, for saving a colour the user picked.
    var hexString: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
