import SwiftUI

/// App appearance choices, stored in app settings.
///
/// Read through `Appearance.current` by views that draw with fixed sizes and
/// colours; the root view rebuilds its content when any of these change.
enum Appearance {
    static let themeKey = "conduit.appearance.theme"
    static let accentKey = "conduit.appearance.accent"
    static let backdropKey = "conduit.appearance.backdrop"
    static let textSizeKey = "conduit.appearance.textSize"
    static let showReasoningKey = "conduit.appearance.showReasoning"

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "Match iPhone"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        var scheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum Backdrop: String, CaseIterable, Identifiable {
        case aurora, dusk, ocean, forest, plain
        var id: String { rawValue }
        var title: String {
            switch self {
            case .aurora: "Aurora"
            case .dusk: "Dusk"
            case .ocean: "Ocean"
            case .forest: "Forest"
            case .plain: "Plain"
            }
        }

        func colors(dark: Bool) -> [Color] {
            switch (self, dark) {
            case (.aurora, false):
                return [Color(red: 0.93, green: 0.95, blue: 1.00), Color(red: 0.97, green: 0.94, blue: 0.99),
                        Color(red: 0.91, green: 0.96, blue: 0.97)]
            case (.aurora, true):
                return [Color(red: 0.05, green: 0.06, blue: 0.11), Color(red: 0.10, green: 0.08, blue: 0.16),
                        Color(red: 0.04, green: 0.07, blue: 0.10)]
            case (.dusk, false):
                return [Color(red: 1.00, green: 0.93, blue: 0.90), Color(red: 0.97, green: 0.90, blue: 0.96),
                        Color(red: 0.92, green: 0.91, blue: 1.00)]
            case (.dusk, true):
                return [Color(red: 0.14, green: 0.06, blue: 0.10), Color(red: 0.10, green: 0.05, blue: 0.16),
                        Color(red: 0.05, green: 0.05, blue: 0.13)]
            case (.ocean, false):
                return [Color(red: 0.88, green: 0.96, blue: 1.00), Color(red: 0.90, green: 0.98, blue: 0.97),
                        Color(red: 0.86, green: 0.92, blue: 0.99)]
            case (.ocean, true):
                return [Color(red: 0.02, green: 0.08, blue: 0.14), Color(red: 0.02, green: 0.11, blue: 0.13),
                        Color(red: 0.03, green: 0.05, blue: 0.12)]
            case (.forest, false):
                return [Color(red: 0.91, green: 0.97, blue: 0.91), Color(red: 0.95, green: 0.97, blue: 0.90),
                        Color(red: 0.89, green: 0.95, blue: 0.93)]
            case (.forest, true):
                return [Color(red: 0.03, green: 0.10, blue: 0.06), Color(red: 0.06, green: 0.10, blue: 0.05),
                        Color(red: 0.03, green: 0.07, blue: 0.08)]
            case (.plain, false):
                return [Color(white: 0.96), Color(white: 0.96)]
            case (.plain, true):
                return [Color(white: 0.06), Color(white: 0.06)]
            }
        }
    }

    enum TextSize: String, CaseIterable, Identifiable {
        case small, standard, large, larger
        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: "Small"
            case .standard: "Standard"
            case .large: "Large"
            case .larger: "Larger"
            }
        }
        var scale: CGFloat {
            switch self {
            case .small: return 0.9
            case .standard: return 1
            case .large: return 1.12
            case .larger: return 1.25
            }
        }
    }

    static var theme: Theme {
        Theme(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .system
    }

    static var backdrop: Backdrop {
        Backdrop(rawValue: UserDefaults.standard.string(forKey: backdropKey) ?? "") ?? .aurora
    }

    static var textScale: CGFloat {
        (TextSize(rawValue: UserDefaults.standard.string(forKey: textSizeKey) ?? "") ?? .standard).scale
    }

    /// The app's highlight colour: the user's choice, or the app's own.
    static var accent: Color {
        let hex = UserDefaults.standard.string(forKey: accentKey) ?? ""
        return Color(hex: hex) ?? .accentColor
    }
}

extension Color {
    /// The highlight colour chosen in Settings > Appearance.
    static var conduitAccent: Color { Appearance.accent }
}

/// Settings > Appearance.
struct AppearanceSettingsView: View {
    @AppStorage(Appearance.themeKey) private var theme = Appearance.Theme.system.rawValue
    @AppStorage(Appearance.accentKey) private var accentHex = ""
    @AppStorage(Appearance.backdropKey) private var backdrop = Appearance.Backdrop.aurora.rawValue
    @AppStorage(Appearance.textSizeKey) private var textSize = Appearance.TextSize.standard.rawValue
    @AppStorage(Appearance.showReasoningKey) private var showReasoning = true
    @AppStorage(VolumeKeys.enabledKey) private var volumeKeys = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Theme", selection: $theme) {
                    ForEach(Appearance.Theme.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                    swatch(hex: "", color: .accentColor, name: "Default")
                    ForEach(AccentPalette.palette) { item in
                        swatch(hex: item.hex, color: Color(hex: item.hex) ?? .accentColor, name: item.name)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Highlight colour")
            } footer: {
                Text("Used for buttons, switches and the loading animation.")
            }

            Section("Background") {
                ForEach(Appearance.Backdrop.allCases) { style in
                    Button {
                        backdrop = style.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            LinearGradient(colors: style.colors(dark: colorScheme == .dark),
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                                .frame(width: 44, height: 30)
                                .clipShape(.rect(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.3))
                                }
                            Text(style.title).foregroundStyle(.primary)
                            Spacer()
                            if backdrop == style.rawValue {
                                Image(systemName: "checkmark").foregroundStyle(Color.conduitAccent)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Chat text size") {
                Picker("Text size", selection: $textSize) {
                    ForEach(Appearance.TextSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: 16 * (Appearance.TextSize(rawValue: textSize)?.scale ?? 1)))
            }

            Section {
                Toggle("Show thinking", isOn: $showReasoning)
            } header: {
                Text("Reasoning")
            } footer: {
                Text("Controls whether thinking appears in the conversation. Models can still think when it "
                    + "is hidden.")
            }

            Section {
                Toggle("Volume buttons open the menu", isOn: $volumeKeys)
                    .onChange(of: volumeKeys) { _, on in
                        if on { VolumeKeys.shared.start() } else { VolumeKeys.shared.stop() }
                    }
            } header: {
                Text("Controls")
            } footer: {
                Text("Press volume up then down quickly, or one button twice quickly, to open or close the "
                    + "menu. Holding a button still changes the volume. Presses at full or zero volume "
                    + "cannot be seen by apps.")
            }

            Section {
                Button("Reset appearance") {
                    theme = Appearance.Theme.system.rawValue
                    accentHex = ""
                    backdrop = Appearance.Backdrop.aurora.rawValue
                    textSize = Appearance.TextSize.standard.rawValue
                    showReasoning = true
                }
            }
        }
    }

    private func swatch(hex: String, color: Color, name: String) -> some View {
        let selected = accentHex.caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            accentHex = hex
        } label: {
            Circle()
                .fill(color)
                .frame(width: 32, height: 32)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
