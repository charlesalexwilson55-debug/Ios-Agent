import SwiftUI

/// The bottom command bar: the plus menu, one wide glass text field, and Send.
///
/// Everything that used to sit on the bar (Think, Online, Research) and the
/// personality picker live in the plus menu, so the field gets the width.
/// Models are chosen from the sidebar.
///
/// The bar is installed via `safeAreaInset(edge: .bottom)` by the caller
/// rather than an `overlay`, because an inset makes the scroll view above it
/// aware of the bar's height. With an overlay the last line of the transcript
/// sits permanently underneath the glass, and SwiftUI's automatic keyboard
/// avoidance does not apply.
struct GlassCommandBar: View {
    @Binding var draft: String
    /// Qwen3 reasoning mode: on for maths and code, off for quick requests.
    @Binding var thinking: Bool
    /// Whether the model may use the internet.
    @Binding var online: Bool
    /// Research mode: follows a subject across many web pages.
    @Binding var research: Bool
    /// Owned by the caller, which also closes it on a tap outside the bar.
    @Binding var menuOpen: Bool
    /// The work level slider, and whether Auto sets it per message instead.
    @Binding var level: WorkLevel
    @Binding var autoLevel: Bool

    let personas: [Persona]
    let selectedPersona: Persona?
    let onSelectPersona: (UUID?) -> Void
    /// Opens the Personalities page; true also starts a new personality.
    let onManagePersonas: (_ createNew: Bool) -> Void

    let isWorking: Bool
    let isModelLoaded: Bool

    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool

    /// Every control on the bar is centred on the same line: half the height
    /// of a one-line bar, measured from its bottom edge. They sit at the
    /// bottom as the text grows.
    private static let controlCentre: CGFloat = 28
    private static let smallButton: CGFloat = 30
    private static let plusLeading: CGFloat = 8
    private static let closeSize: CGFloat = 42
    private static let menuWidth: CGFloat = 304
    private static let levelColumnWidth: CGFloat = 106
    /// Personalities listed in the menu before "All personalities".
    private static let menuPersonaLimit = 5

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isModelLoaded
    }

    var body: some View {
        inputField
            // Outside the glass, so the menu is not drawn inside the bar's
            // material, and taller than the bar, so it rises above it.
            .overlay(alignment: .bottomLeading) {
                if menuOpen {
                    plusMenu
                        // The menu's close button lands exactly on the plus.
                        .padding(.leading, Self.plusLeading + Self.smallButton / 2 - Self.closeSize / 2)
                        .padding(.bottom, Self.controlCentre - Self.closeSize / 2)
                        .transition(.scale(scale: 0.2, anchor: .bottomLeading).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: menuOpen)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .onChange(of: isFocused) { _, focused in
                if focused { menuOpen = false }
            }
    }

    // MARK: - Input

    private var inputField: some View {
        HStack(alignment: .bottom, spacing: 6) {
            plusButton
                .padding(.leading, Self.plusLeading)
                .padding(.bottom, bottomPadding(for: Self.smallButton))

            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .lineLimit(1...6)
                .focused($isFocused)
                .submitLabel(.send)
                .disabled(!isModelLoaded)
                .onSubmit {
                    if canSend { send() }
                }
                .padding(.vertical, 17)

            sendButton
                .padding(.trailing, 10)
                .padding(.bottom, bottomPadding(for: Self.smallButton))
        }
        // Bottom-aligned, so the controls' padding is measured from the
        // bar's own bottom edge.
        .frame(maxWidth: .infinity, minHeight: 2 * Self.controlCentre, alignment: .bottom)
        .contentShape(.rect)
        .onTapGesture { if isModelLoaded { isFocused = true } }
        .glassEffect(.regular, in: .rect(cornerRadius: Self.controlCentre))
    }

    /// Bottom padding that centres a control of this height on the bar's
    /// first line.
    private func bottomPadding(for height: CGFloat) -> CGFloat {
        max(0, Self.controlCentre - height / 2)
    }

    private var placeholder: String {
        if !isModelLoaded { return "Choose a model from the menu to begin" }
        if research { return "Who or what should Conduit research?" }
        if let selectedPersona { return "Message \(selectedPersona.name)" }
        return "Ask anything, or tell Conduit what to do"
    }

    // MARK: - Plus button

    /// Neutral with no personality. With one, the plus takes its colour,
    /// and fills with it once there is something typed.
    private var plusButton: some View {
        let tint = selectedPersona?.color
        let typing = !draft.isEmpty
        let fill: Color = {
            guard let tint else { return Color.primary.opacity(0.08) }
            return typing ? tint : tint.opacity(0.2)
        }()
        let glyph: Color = {
            guard let tint else { return Color.primary }
            return typing ? Color.white : tint
        }()
        return Button {
            if !menuOpen { isFocused = false }
            menuOpen.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(glyph)
                .frame(width: Self.smallButton, height: Self.smallButton)
                .background { Circle().fill(fill) }
                .overlay(alignment: .topTrailing) {
                    if research {
                        Image(systemName: "binoculars.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background { Circle().fill(Color.conduitAccent) }
                            .offset(x: 4, y: -4)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: typing)
        .animation(.easeOut(duration: 0.2), value: selectedPersona?.colorHex)
        .accessibilityLabel("Options")
        .accessibilityValue(accessibilityState)
        .accessibilityHint("Personality, Think, Online and Research.")
    }

    private var accessibilityState: String {
        var parts: [String] = []
        if let selectedPersona { parts.append(selectedPersona.name) }
        if research { parts.append("Research on") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Plus menu

    /// A white panel that grows up out of the plus button: personalities
    /// and switches on the left, the work level on the right.
    private var plusMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                optionsColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 6)
                levelColumn
                    .frame(width: Self.levelColumnWidth)
            }
            .fixedSize(horizontal: false, vertical: true)

            Button {
                menuOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: Self.closeSize, height: Self.closeSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.black.opacity(0.7))
            .accessibilityLabel("Close menu")
        }
        .padding(.top, 8)
        .frame(width: Self.menuWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.2), radius: 14, y: 4)
        }
        .environment(\.colorScheme, .light)
    }

    private var optionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Personality")
            personaRow(id: nil, name: "Conduit", color: nil)
            ForEach(menuPersonas) { persona in
                personaRow(id: persona.id, name: persona.name, color: persona.color)
            }
            menuRow(symbol: hasMorePersonas ? "ellipsis.circle" : "plus.circle",
                    title: hasMorePersonas ? "All personalities" : "New personality",
                    trailing: nil, highlighted: false) {
                menuOpen = false
                onManagePersonas(!hasMorePersonas)
            }

            Divider().padding(.vertical, 4).padding(.horizontal, 12)

            menuRow(symbol: thinking ? "brain.fill" : "brain", title: "Think",
                    trailing: autoLevel ? "Auto" : (thinking ? "On" : "Off"),
                    highlighted: thinking && !autoLevel) {
                thinking.toggle()
            }
            menuRow(symbol: "globe", title: "Online",
                    trailing: online ? "On" : "Off", highlighted: online) {
                online.toggle()
            }
            menuRow(symbol: research ? "binoculars.fill" : "binoculars", title: "Research",
                    trailing: research ? "On" : (autoLevel ? "Auto" : "Off"), highlighted: research) {
                research.toggle()
            }
        }
    }

    private var levelColumn: some View {
        let tint = selectedPersona?.color ?? Color.conduitAccent
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Level")
                .padding(.leading, -4)
            Button {
                autoLevel.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wand.and.stars")
                    Text("Auto")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(autoLevel ? Color.white : Color.black.opacity(0.7))
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background { Capsule().fill(autoLevel ? tint : Color.black.opacity(0.07)) }
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Automatic level")
            .accessibilityValue(autoLevel ? "On" : "Off")
            .accessibilityHint("Chooses the level, Think and Research for each message.")

            LevelSlider(level: $level, tint: tint, dimmed: autoLevel) {
                autoLevel = false
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }

    private var hasMorePersonas: Bool {
        personas.count > Self.menuPersonaLimit
    }

    /// The first few personalities, always including the one in use.
    private var menuPersonas: [Persona] {
        var shown = Array(personas.prefix(Self.menuPersonaLimit))
        if let selectedPersona, !shown.contains(where: { $0.id == selectedPersona.id }) {
            if shown.count == Self.menuPersonaLimit { shown.removeLast() }
            shown.append(selectedPersona)
        }
        return shown
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.45))
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 4)
    }

    private func personaRow(id: UUID?, name: String, color: Color?) -> some View {
        let selected = selectedPersona?.id == id
        return Button {
            onSelectPersona(id)
            menuOpen = false
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(color ?? Color.black.opacity(0.12))
                    .frame(width: 18, height: 18)
                    .overlay {
                        if color == nil {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.black.opacity(0.6))
                        }
                    }
                    .frame(width: 24)
                Text(name.isEmpty ? "Untitled" : name)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.black)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color ?? Color.conduitAccent)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func menuRow(
        symbol: String,
        title: String,
        trailing: String?,
        highlighted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(highlighted ? Color.conduitAccent : Color.black.opacity(0.75))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.black)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(highlighted ? Color.conduitAccent : Color.black.opacity(0.4))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(trailing ?? "")
    }

    // MARK: - Send

    private func send() {
        menuOpen = false
        onSend()
    }

    private var sendButton: some View {
        let enabled = isWorking || canSend
        return Button(action: isWorking ? onStop : send) {
            Image(systemName: isWorking ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: Self.smallButton, height: Self.smallButton)
                .background {
                    Circle().fill(enabled ? Color.conduitAccent : Color.secondary.opacity(0.35))
                }
                .contentShape(.circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.easeOut(duration: 0.18), value: isWorking)
        .accessibilityLabel(isWorking ? "Stop" : "Send")
    }
}

/// A vertical slider with five stops: Ultra at the top, Normal at the bottom.
private struct LevelSlider: View {
    @Binding var level: WorkLevel
    let tint: Color
    /// Shown faded while Auto is choosing.
    let dimmed: Bool
    /// Called when the user moves it, which takes over from Auto.
    let onUserChange: () -> Void

    private static let stop: CGFloat = 34
    private static let thumb: CGFloat = 22
    private static let trackWidth: CGFloat = 6

    /// Top to bottom.
    private let levels: [WorkLevel] = WorkLevel.allCases.reversed()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            track
            VStack(alignment: .leading, spacing: 0) {
                ForEach(levels) { item in
                    Text(item.title)
                        .font(.system(size: 14, weight: item == level ? .semibold : .regular))
                        .foregroundStyle(item == level ? Color.black : Color.black.opacity(0.5))
                        .frame(height: Self.stop)
                }
            }
        }
        .frame(height: Self.stop * CGFloat(levels.count), alignment: .top)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in select(at: value.location.y) }
        )
        .opacity(dimmed ? 0.45 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: level)
        .sensoryFeedback(.selection, trigger: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Work level")
        .accessibilityValue(level.title)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(by: 1)
            case .decrement: step(by: -1)
            @unknown default: break
            }
        }
    }

    private var index: Int {
        levels.firstIndex(of: level) ?? levels.count - 1
    }

    private var track: some View {
        let count = levels.count
        let position = CGFloat(index)
        let centre = Self.stop / 2
        return ZStack(alignment: .top) {
            Capsule()
                .fill(Color.black.opacity(0.1))
                .frame(width: Self.trackWidth, height: CGFloat(count - 1) * Self.stop + Self.trackWidth)
                .offset(y: centre - Self.trackWidth / 2)
            Capsule()
                .fill(tint)
                .frame(width: Self.trackWidth,
                       height: CGFloat(count - 1 - index) * Self.stop + Self.trackWidth)
                .offset(y: position * Self.stop + centre - Self.trackWidth / 2)
            ForEach(0..<count, id: \.self) { stop in
                Circle()
                    .fill(stop >= index ? Color.white.opacity(0.9) : Color.black.opacity(0.25))
                    .frame(width: 4, height: 4)
                    .offset(y: CGFloat(stop) * Self.stop + centre - 2)
            }
            Circle()
                .fill(Color.white)
                .frame(width: Self.thumb, height: Self.thumb)
                .overlay { Circle().strokeBorder(tint, lineWidth: 3) }
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .offset(y: position * Self.stop + (Self.stop - Self.thumb) / 2)
        }
        .frame(width: Self.thumb, height: Self.stop * CGFloat(count), alignment: .top)
    }

    private func select(at y: CGFloat) {
        let row = min(max(Int(y / Self.stop), 0), levels.count - 1)
        let chosen = levels[row]
        guard chosen != level || dimmed else { return }
        level = chosen
        onUserChange()
    }

    private func step(by amount: Int) {
        guard let next = WorkLevel(rawValue: level.rawValue + amount) else { return }
        level = next
        onUserChange()
    }
}
