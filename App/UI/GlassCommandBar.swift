import SwiftUI

/// The bottom command bar: one wide glass field with the Think and Online
/// switches on the left and Send on the right.
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
    let isWorking: Bool
    let isModelLoaded: Bool

    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isModelLoaded
    }

    var body: some View {
        inputField
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    // MARK: - Input

    private var inputField: some View {
        HStack(alignment: .bottom, spacing: 4) {
            HStack(spacing: 0) {
                thinkButton
                onlineButton
            }
            .padding(.leading, 8)
            .padding(.bottom, 8)

            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .lineLimit(1...6)
                .focused($isFocused)
                .submitLabel(.send)
                .disabled(!isModelLoaded)
                .onSubmit {
                    if canSend { onSend() }
                }
                .padding(.leading, 4)
                .padding(.vertical, 15)

            sendButton
                .padding(.trailing, 8)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(.rect)
        .onTapGesture { if isModelLoaded { isFocused = true } }
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

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
        isModelLoaded ? "Ask anything, or tell Conduit what to do" : "Choose a model from the menu to begin"
    }

    private var sendButton: some View {
        Button(action: isWorking ? onStop : onSend) {
            Image(systemName: isWorking ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glassProminent)
        .clipShape(.circle)
        .disabled(!isWorking && !canSend)
        .animation(.easeOut(duration: 0.18), value: isWorking)
        .accessibilityLabel(isWorking ? "Stop" : "Send")
    }
}
