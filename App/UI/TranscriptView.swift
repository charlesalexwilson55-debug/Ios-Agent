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
    /// The colour of the waiting animation.
    var accent: Color = .conduitAccent
    /// Stops a step or skips an item of an activity: its id and the entry.
    var onCancelActivity: (UUID, UUID) -> Void = { _, _ in }
    var isWorking: Bool = false
    @AppStorage("conduit.thinking") private var thinkingEnabled = true
    var onSelectResearchCandidate: (String, UUID) -> Void = { _, _ in }
    var onRejectResearchCandidate: (String, UUID) -> Void = { _, _ in }
    @State private var scrollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
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
                        .frame(height: 72)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }
            // The glass bar floats over the top edge of the scroll content;
            // this keeps the system's edge-fade consistent with it.
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: entries.count) { _, _ in scroll(proxy) }
            .onChange(of: entries.last?.text) { _, _ in scroll(proxy) }
            .onChange(of: entries.last?.reasoning) { _, _ in scroll(proxy) }
            .onChange(of: entries.compactMap(\.activity)) { _, _ in scroll(proxy) }
            .onChange(of: isWorking) { _, _ in scroll(proxy) }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { _ in scroll(proxy) }
            .onDisappear { scrollTask?.cancel() }
        }
        if isWorking {
            // One owner outside lazy scroll rows: research placeholders cannot
            // restart the animation or move it underneath the composer.
            ConduitLoader(color: accent, status: activityLabel)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
        }
        }
        .background(BackdropView())
    }

    private static let bottomAnchor = "conduit.transcript.bottom"

    private var activityLabel: String {
        TranscriptProgress.label(rows: entries.map {
            TranscriptProgress.Row(isUser: $0.kind == .user, isTool: $0.kind == .tool,
                isStreaming: $0.isStreaming, hasAnswer: !$0.text.isEmpty,
                runningTitles: $0.activity?.steps.filter { $0.status == .running }.map(\.title) ?? [])
        }, thinking: thinkingEnabled)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            // Row heights update after the text mutation. Scroll after that
            // layout, without overlapping animations for every streamed token.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            if isWorking {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .user:
            UserBubble(text: entry.text, imageIDs: entry.imageIDs)
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                AssistantText(entry: entry, accent: accent)
                if !entry.researchCandidates.isEmpty {
                    ResearchCandidatesView(candidates: entry.researchCandidates, isWorking: isWorking,
                        onSelect: { onSelectResearchCandidate($0.id, entry.id) },
                        onReject: { onRejectResearchCandidate($0.id, entry.id) })
                }
            }
        case .tool:
            // Older saved chats can contain recall chips from prior builds.
            if entry.text.range(of: #"^Found \d+ notes?: "#, options: .regularExpression) == nil {
                ToolChip(text: entry.text, outcome: entry.toolOutcome)
                if let id = entry.objectID { ObjectPreview(id: id) }
                ForEach(entry.imageIDs, id: \.self) { id in StoredImageView(id: id, maxHeight: 340) }
            }
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
    var imageIDs: [UUID] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !imageIDs.isEmpty {
                HStack(spacing: 6) {
                    Spacer(minLength: 40)
                    ForEach(imageIDs, id: \.self) { id in
                        StoredImageView(id: id, maxHeight: 150, cornerRadius: 14)
                    }
                }
            }
            bubble
        }
    }

    private var bubble: some View {
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

    @AppStorage(Appearance.showReasoningKey) private var showReasoning = true
    @AppStorage("conduit.thinking") private var thinkingEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showReasoning && thinkingEnabled && !entry.reasoning.isEmpty {
                ReasoningView(reasoning: entry.reasoning,
                              isThinking: entry.isStreaming && entry.text.isEmpty)
            }

            ForEach(entry.imageIDs, id: \.self) { id in
                StoredImageView(id: id, maxHeight: 340)
            }

                ForEach(MessageSegment.parse(entry.text)) { segment in
                    switch segment.kind {
                    case .prose(let prose):
                        ProseText(markdown: prose)
                    case .code(let language, let code):
                        CodeBlockView(language: language, code: code)
                    }
                }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

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
        let prose = ResponseTextCleaner.displayProse(markdown)
        return (try? AttributedString(markdown: prose, options: options))
            ?? AttributedString(prose)
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Text" : language)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
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
                .foregroundStyle(copied ? Color.green : Color.white.opacity(0.75))
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
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .background(Color.black.opacity(0.7), in: .rect(cornerRadius: 12))
        .glassEffect(.regular.tint(.black.opacity(0.65)), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }
}

private struct ReasoningView: View {
    let reasoning: String
    let isThinking: Bool

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ProseText(markdown: ResponseTextCleaner.clean(reasoning))
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
