import SwiftUI

/// A full-width composer with a single expandable options button.
struct GlassCommandBar: View {
    @Binding var draft: String
    @Binding var thinking: Bool
    @Binding var online: Bool
    @Binding var research: Bool
    @Binding var menuOpen: Bool
    let isWorking: Bool
    let isModelLoaded: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    @FocusState private var focused: Bool

    private var canSend: Bool {
        isModelLoaded && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { menuOpen.toggle() }
            } label: {
                Image(systemName: menuOpen ? "xmark" : "plus")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(menuOpen ? "Close options" : "Chat options")
            .accessibilityValue(menuOpen ? "Expanded" : "Collapsed")
            TextField(isModelLoaded ? "Ask anything, or tell Conduit what to do" : "Choose a model from the menu", text: $draft, axis: .vertical)
                .font(.system(size: 17))
                .lineLimit(1...6)
                .padding(.vertical, 11)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send() }
            Button {
                if isWorking { onStop() } else { send() }
            } label: {
                Image(systemName: isWorking ? "stop.fill" : "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.conduitAccent.opacity(isWorking || canSend ? 1 : 0.35), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!isWorking && !canSend)
            .accessibilityLabel(isWorking ? "Stop" : "Send")
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 56)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .overlay(alignment: .bottomLeading) {
            if menuOpen {
                VStack(spacing: 4) {
                    option("Think", symbol: "brain", value: $thinking)
                    option("Online", symbol: "globe", value: $online)
                    option("Research", symbol: "magnifyingglass", value: $research)
                }
                .padding(12)
                .frame(width: 238)
                .foregroundStyle(.white)
                .glassEffect(.regular.tint(.black.opacity(0.8)), in: .rect(cornerRadius: 25))
                .overlay { RoundedRectangle(cornerRadius: 25).strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
                .environment(\.colorScheme, .dark)
                .alignmentGuide(.bottom) { $0[.bottom] + 68 }
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomLeading)))
                .zIndex(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func option(_ title: String, symbol: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) { Label(title, systemImage: symbol) }
            .font(.system(size: 15, weight: .medium))
            .tint(Color.conduitAccent)
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
    }

    private func send() {
        guard canSend && !isWorking else { return }
        menuOpen = false
        focused = false
        onSend()
    }
}
