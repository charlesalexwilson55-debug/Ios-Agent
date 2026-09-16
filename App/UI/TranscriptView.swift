import SwiftUI

/// The conversation above the command bar.
///
/// Tool activity is rendered as a narrow chip rather than a chat bubble. That
/// is a deliberate hierarchy: the user cares that the event was added, not
/// that a function named `create_event` returned JSON. Chips also make the
/// awaiting-confirmation state visually distinct from the done state, which is
/// the distinction this app most needs to communicate.
struct TranscriptView: View {
    let entries: [TranscriptEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if entries.isEmpty {
                        EmptyStateView()
                            .padding(.top, 60)
                    }
                    ForEach(entries) { entry in
                        row(for: entry)
                            .id(entry.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    // Anchor for auto-scroll. Scrolling to the last entry's own
                    // id stops short while that entry is still growing during
                    // streaming; a zero-height tail anchor always lands at the
                    // true bottom.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            // The glass bar floats over the top edge of the scroll content;
            // this keeps the system's edge-fade consistent with it.
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: entries.count) { _, _ in scroll(proxy) }
            .onChange(of: entries.last?.text) { _, _ in scroll(proxy) }
        }
    }

    private static let bottomAnchor = "conduit.transcript.bottom"

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.22)) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func row(for entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .user:
            UserBubble(text: entry.text)
        case .assistant:
            AssistantText(text: entry.text, isStreaming: entry.isStreaming)
        case .tool:
            ToolChip(text: entry.text, outcome: entry.toolOutcome)
        case .error:
            ErrorRow(text: entry.text)
        }
    }
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(size: 16))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular.tint(.accentColor.opacity(0.28)), in: .rect(cornerRadius: 19))
                .textSelection(.enabled)
        }
    }
}

private struct AssistantText: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isStreaming {
                // A caret rather than a spinner: generation is token-by-token,
                // and a caret reads as "still writing" without implying a
                // known duration the way a progress indicator does.
                StreamingCaret()
            }
        }
    }
}

/// Blinking caret shown while tokens are still arriving.
///
/// Driven by an explicit repeating animation rather than `.symbolEffect`,
/// which only animates SF Symbols and would be a silent no-op on a shape.
private struct StreamingCaret: View {
    @State private var dimmed = false

    var body: some View {
        Capsule()
            .frame(width: 2, height: 15)
            .foregroundStyle(.secondary)
            .opacity(dimmed ? 0.15 : 0.8)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true),
                       value: dimmed)
            .onAppear { dimmed = true }
    }
}

private struct ToolChip: View {
    let text: String
    let outcome: TranscriptEntry.Outcome?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassEffect(.clear, in: .rect(cornerRadius: 13))
    }

    private var glyph: String {
        switch outcome {
        case .done?: return "checkmark.circle.fill"
        case .awaitingUser?: return "hand.tap.fill"
        case .handedOff?: return "arrow.up.forward.app.fill"
        case .failed?: return "exclamationmark.triangle.fill"
        case nil: return "circle.dotted"
        }
    }

    private var tint: Color {
        switch outcome {
        case .done?: return .green
        // Amber, not green: this state means the user still has to act, and
        // colouring it like success is exactly the confusion to avoid.
        case .awaitingUser?: return .orange
        // Blue, not amber: a hand-off needs nothing from the user, so it must
        // not carry the same "your turn" signal as a staged message.
        case .handedOff?: return .blue
        case .failed?: return .red
        case nil: return .secondary
        }
    }
}

private struct ErrorRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.red.opacity(0.18)), in: .rect(cornerRadius: 14))
    }
}

/// First-run guidance.
///
/// The examples are chosen to teach the capability boundary implicitly: the
/// first two complete with no taps, the third is explicitly described as a
/// draft. Setting that expectation before the first request is cheaper than
/// correcting it afterwards.
private struct EmptyStateView: View {
    /// A named struct rather than a tuple: Swift has no key paths to tuple
    /// elements, so `ForEach(examples, id: \.1)` does not compile.
    private struct Example: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
    }

    private let examples = [
        Example(icon: "calendar", text: "Put dinner with Sam in my calendar for Friday at 8"),
        Example(icon: "checklist", text: "Remind me to renew the car insurance on Thursday morning"),
        Example(icon: "message", text: "Draft a text to Mum saying I will be late"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Conduit")
                    .font(.system(size: 26, weight: .semibold))
                Text("A local model that does things on this phone. Nothing leaves the device.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(examples) { example in
                    HStack(spacing: 9) {
                        Image(systemName: example.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(example.text)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .glassEffect(.clear, in: .rect(cornerRadius: 17))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
