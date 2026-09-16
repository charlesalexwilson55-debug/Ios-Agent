import SwiftUI

/// The bottom command bar: one wide glass field with the plus menu, Think
/// and Online on the left and Send on the right.
///
/// Models are chosen from the sidebar, so the field gets the full width of
/// the phone.
///
/// The bar is installed via `safeAreaInset(edge: .bottom)` by the caller
/// rather than an `overlay`, because an inset makes the scroll view above it
/// aware of the bar's height. With an overlay the last line of the transcript
/// sits permanently underneath the glass, and SwiftUI's automatic keyboard
/// avoidance does not apply.
struct GlassCommandBar: View {
    @Binding var draft: String
    /// Qwen3 reasoning mode. Stays on the bar rather than in settings because
    /// it is a per-question choice: on for maths and code, off for a quick
    /// reminder that should not take twenty seconds.
    @Binding var thinking: Bool
    /// Whether the model may use the internet. Also on the bar, because it
    /// is the switch someone reaches for when they want a fresh answer.
    @Binding var online: Bool
    /// Research mode, switched from the plus menu.
    @Binding var research: Bool
    let isWorking: Bool
    let isModelLoaded: Bool

    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool
    @State private var menuOpen = false

    /// Every control on the bar is centred on the same line: half the height
    /// of a one-line bar, measured from its bottom edge. They sit at the
    /// bottom as the text grows.
    private static let controlCentre: CGFloat = 28
    private static let smallButton: CGFloat = 30
    private static let menuWidth: CGFloat = 42
    private static let plusLeading: CGFloat = 8

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
                        .padding(.leading, Self.plusLeading + Self.smallButton / 2 - Self.menuWidth / 2)
                        .padding(.bottom, Self.controlCentre - Self.menuWidth / 2)
                        .transition(.scale(scale: 0.3, anchor: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: menuOpen)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .onChange(of: isFocused) { _, focused in
                if focused { menuOpen = false }
            }
    }

    // MARK: - Input

    private var inputField: some View {
        HStack(alignment: .bottom, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                plusButton
                    .padding(.bottom, bottomPadding(for: Self.smallButton))
                thinkButton
                    .padding(.bottom, bottomPadding(for: 34))
                onlineButton
                    .padding(.bottom, bottomPadding(for: 34))
            }
            .padding(.leading, Self.plusLeading)

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
                .padding(.leading, 4)
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

    // MARK: - Plus menu

    private var plusButton: some View {
        Button {
            menuOpen.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: Self.smallButton, height: Self.smallButton)
                .foregroundStyle(research ? Color.white : Color.primary)
                .background {
                    Circle().fill(research ? Color.accentColor : Color.primary.opacity(0.08))
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityValue(research ? "Research on" : "")
        .accessibilityHint("Shows Research.")
    }

    /// A white capsule that grows up out of the plus button. The close
    /// button at its foot sits exactly over the plus.
    private var plusMenu: some View {
        VStack(spacing: 4) {
            menuItem(
                symbol: "binoculars",
                selectedSymbol: "binoculars.fill",
                isOn: research,
                label: "Research",
                hint: "Follows a person or topic across several web pages, checking each one "
                    + "is about the same subject, then writes up what it found."
            ) {
                research.toggle()
                menuOpen = false
            }

            Button {
                menuOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: Self.menuWidth, height: Self.menuWidth)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.black.opacity(0.7))
            .accessibilityLabel("Close menu")
        }
        .padding(.top, 4)
        .frame(width: Self.menuWidth)
        .background {
            Capsule()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
    }

    private func menuItem(
        symbol: String,
        selectedSymbol: String,
        isOn: Bool,
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: isOn ? selectedSymbol : symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(isOn ? Color.white : Color.black.opacity(0.75))
                .background {
                    Circle().fill(isOn ? Color.accentColor : Color.clear)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(hint)
    }

    // MARK: - Switches

    private var thinkButton: some View {
        Button {
            thinking.toggle()
        } label: {
            Image(systemName: thinking ? "brain.fill" : "brain")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(thinking ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: thinking)
        .accessibilityLabel("Think")
        .accessibilityValue(thinking ? "On" : "Off")
        .accessibilityHint("Reason step by step before answering. Better for maths and code, slower.")
    }

    private var onlineButton: some View {
        Button {
            online.toggle()
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 34)
                .foregroundStyle(online ? Color.accentColor : Color.secondary)
                .opacity(online ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: online)
        .accessibilityLabel("Online")
        .accessibilityValue(online ? "On" : "Off")
        .accessibilityHint("Let the model search the web, read pages and check the weather.")
    }

    private var placeholder: String {
        if !isModelLoaded { return "Choose a model from the menu to begin" }
        return research ? "Who or what should Conduit research?" : "Ask anything, or tell Conduit what to do"
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
                    Circle().fill(enabled ? Color.accentColor : Color.secondary.opacity(0.35))
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
