import SwiftUI

/// The bottom command bar.
///
/// Two separate glass capsules — the model chip and the input field — sit
/// inside one `GlassEffectContainer`. That is the idiomatic iOS 26 composition
/// and it is not just decoration: a container lets adjacent glass elements
/// share one lighting and blur pass, so they merge where they meet and read as
/// a single control rather than two stickers. It is also cheaper to render
/// than two independent glass surfaces.
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
    let modelLabel: String
    let isWorking: Bool
    let isModelLoaded: Bool

    let onSend: () -> Void
    let onStop: () -> Void
    let onPickModel: () -> Void

    @FocusState private var isFocused: Bool
    @Namespace private var glassNamespace

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isModelLoaded
    }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                modelChip
                inputCapsule
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Model chip

    private var modelChip: some View {
        Button(action: onPickModel) {
            HStack(spacing: 6) {
                Image(systemName: isModelLoaded ? "cpu.fill" : "cpu")
                    .font(.system(size: 15, weight: .medium))
                // The name is hidden once the user starts typing so the field
                // gets the width. On a phone the input matters more than a
                // label the user just read.
                if !isFocused, !modelLabel.isEmpty {
                    Text(modelLabel)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isModelLoaded ? .primary : .secondary)
        // .interactive() gives the press-scale and shimmer the system controls
        // have. Worth applying only to genuinely tappable glass, which this is.
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("model", in: glassNamespace)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isFocused)
        .accessibilityLabel("Choose model")
        .accessibilityValue(isModelLoaded ? modelLabel : "No model loaded")
    }

    // MARK: - Input

    private var inputCapsule: some View {
        HStack(alignment: .bottom, spacing: 4) {
            thinkButton
                .padding(.leading, 6)
                .padding(.bottom, 4)

            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineLimit(1...5)
                .focused($isFocused)
                .submitLabel(.send)
                .disabled(!isModelLoaded)
                .onSubmit {
                    if canSend { onSend() }
                }
                .padding(.leading, 2)
                .padding(.vertical, 11)

            sendButton
                .padding(.trailing, 5)
                .padding(.bottom, 4)
        }
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("input", in: glassNamespace)
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

    private var placeholder: String {
        isModelLoaded ? "Ask Conduit to do something" : "Choose a model to begin"
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
