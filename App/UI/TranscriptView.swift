import SwiftUI
import UIKit

/// The conversation above the command bar.
///
/// Tool activity is rendered as a narrow chip rather than a chat bubble. That
/// is a deliberate hierarchy: the user cares that the event was added, not
/// that a function named `create_event` returned JSON. Chips also make the
/// awaiting-confirmation state visually distinct from the done state, which is
/// the distinction this app most needs to communicate.
struct TranscriptView: View {
    let entries: [TranscriptEntry]
    /// The colour of the waiting animation: the personality's, or the app's.
    var accent: Color = .conduitAccent
    /// Shows another draft of an answer: the draft's index and the entry.
    var onShowDraft: (Int, UUID) -> Void = { _, _ in }
    /// Stops a step or skips an item of an activity: its id and the entry.
    var onCancelActivity: (UUID, UUID) -> Void = { _, _ in }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
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
            AssistantText(entry: entry, accent: accent) { index in
                onShowDraft(index, entry.id)
            }
        case .tool:
            ToolChip(text: entry.text, outcome: entry.toolOutcome)
        case .activity:
            if let log = entry.activity {
                ActivityCard(log: log, accent: accent) { id in
                    onCancelActivity(id, entry.id)
                }
            }
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
                .font(.system(size: 16 * Appearance.textScale))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular.tint(Color.conduitAccent.opacity(0.28)), in: .rect(cornerRadius: 19))
                .textSelection(.enabled)
        }
    }
}

private struct AssistantText: View {
    let entry: TranscriptEntry
    let accent: Color
    let onShowDraft: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !entry.reasoning.isEmpty {
                ReasoningView(reasoning: entry.reasoning,
                              isThinking: entry.isStreaming && entry.text.isEmpty && entry.draftTarget == 0)
            }

            ForEach(MessageSegment.parse(entry.text)) { segment in
                switch segment.kind {
                case .prose(let prose):
                    ProseText(markdown: prose)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }

            if entry.isStreaming {
                ConduitLoader(color: accent, status: draftStatus)
                    .padding(.top, 2)
            } else if entry.drafts.count > 1 {
                DraftNavigator(
                    count: entry.drafts.count,
                    shown: entry.shownDraft,
                    best: entry.bestDraft,
                    label: entry.draftLabels.indices.contains(entry.shownDraft)
                        ? entry.draftLabels[entry.shownDraft] : nil,
                    level: entry.levelTitle,
                    accent: accent,
                    onShow: onShowDraft
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the drafting is doing, or nil when it is not drafting.
    private var draftStatus: String? {
        guard entry.draftTarget > 0 else { return nil }
        if entry.drafts.count < entry.draftTarget {
            return "Writing draft \(entry.drafts.count + 1) of \(entry.draftTarget)\u{2026}"
        }
        return "Comparing \(entry.drafts.count) drafts\u{2026}"
    }
}

/// Arrows under an answer that had several drafts: every draft is kept, so
/// flipping between them is instant.
private struct DraftNavigator: View {
    let count: Int
    let shown: Int
    let best: Int?
    let label: String?
    let level: String?
    let accent: Color
    let onShow: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            arrow("chevron.left", label: "Previous draft", enabled: shown > 0) {
                onShow(shown - 1)
            }
            Text("\(shown + 1) of \(count)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            arrow("chevron.right", label: "Next draft", enabled: shown < count - 1) {
                onShow(shown + 1)
            }
            if let label {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            if shown == best {
                Text("Best")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background { Capsule().fill(accent) }
                    .padding(.leading, 6)
            } else if let best {
                Button("Show best") { onShow(best) }
                    .font(.system(size: 12, weight: .medium))
                    .tint(accent)
                    .padding(.leading, 6)
            }
            if let level {
                Text(level)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .padding(.vertical, 2)
        .glassEffect(.clear, in: .capsule)
        .sensoryFeedback(.selection, trigger: shown)
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }
}

/// Assistant text split into prose and fenced code blocks.
///
/// Parsed on every update while streaming, so an unterminated fence is treated
/// as code: the block renders as code while it is still being written instead
/// of flashing as prose and then snapping into a code box.
struct MessageSegment: Identifiable {
    enum Kind {
        case prose(String)
        case code(language: String, code: String)
    }

    let id: Int
    let kind: Kind

    static func parse(_ text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var language: String?

        func push(_ kind: Kind) {
            segments.append(MessageSegment(id: segments.count, kind: kind))
        }
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { push(.prose(joined)) }
            prose.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = language {
                    push(.code(language: open, code: code.joined(separator: "\n")))
                    code.removeAll()
                    language = nil
                } else {
                    flushProse()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else if language != nil {
                code.append(line)
            } else {
                prose.append(line)
            }
        }

        if let open = language {
            push(.code(language: open, code: code.joined(separator: "\n")))
        }
        flushProse()
        return segments
    }
}

private struct ProseText: View {
    let markdown: String

    var body: some View {
        Text(rendered)
            .font(.system(size: 16 * Appearance.textScale))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline markdown only (bold, italics, `code`, links). Block structure is
    /// handled by MessageSegment, and whitespace is kept so lists and line
    /// breaks survive.
    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.4)

            // Horizontal scroll rather than wrapping: wrapped code loses its
            // indentation, which in Python changes what the code means.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13 * Appearance.textScale, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }
}

private struct ReasoningView: View {
    let reasoning: String
    let isThinking: Bool

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .symbolEffect(.pulse, isActive: isThinking)
                Text(isThinking ? "Thinking…" : "Thought process")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .tint(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.clear, in: .rect(cornerRadius: 12))
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
