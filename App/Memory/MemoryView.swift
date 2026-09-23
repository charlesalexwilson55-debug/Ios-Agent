import SwiftUI

/// The Memory page: every saved chat as a card, two across and three down,
/// newest first. Everything in them is searchable by later chats.
struct MemoryView: View {
    @State private var store = ConversationStore.shared
    let isWorking: Bool
    let onOpen: (ChatRecord) -> Void
    @State private var search = ""
    @State private var hits: [KnowledgeIndex.Hit] = []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                // Three rows of cards fill the visible height.
                let cardHeight = max(120, (geometry.size.height - 12 * 2 - 24) / 3)
                ScrollView {
                    if !hits.isEmpty {
                        recallResults
                    }
                    if store.chats.isEmpty {
                        ContentUnavailableView(
                            "No memories yet",
                            systemImage: "brain",
                            description: Text("Each chat is saved here with how Conduit worked through it. "
                                + "Later chats look back at them, even offline.")
                        )
                        .padding(.top, 40)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.chats) { chat in
                            Button {
                                onOpen(chat)
                            } label: {
                                MemoryCard(chat: chat)
                                    .frame(height: cardHeight)
                            }
                            .buttonStyle(.plain)
                            .disabled(isWorking)
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    store.delete(chat.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Memory")
            .searchable(text: $search, prompt: "Search everything Conduit remembers")
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: search) { _, text in
                if text.isEmpty { hits = [] }
            }
        }
    }

    private var recallResults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Closest memories")
                .font(.headline)
            ForEach(hits) { hit in
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.title).font(.subheadline.weight(.semibold))
                    Text(hit.text).font(.footnote).foregroundStyle(.secondary).lineLimit(5)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func runSearch() {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            hits = (try? await KnowledgeIndex.shared.search(text, sources: [.memory], limit: 5)) ?? []
        }
    }
}

/// One chat on the Memory grid.
private struct MemoryCard: View {
    let chat: ChatRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chat.title.isEmpty ? "Untitled chat" : chat.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .padding(.trailing, 18)
            Spacer(minLength: 0)
            if let last = chat.thoughts.last {
                Text(last.answer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack {
                Text(chat.updated.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                Text("\(chat.thoughts.count)")
                Image(systemName: "brain")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// Inside one chat: each thought process in order, linked to the ones
/// before and after it across all chats.
struct ChatMemoryView: View {
    let chatID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var store = ConversationStore.shared
    @State private var focused: ConversationStore.ThoughtLink?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if let chat = store.chat(chatID) {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(chat.thoughts) { thought in
                                ThoughtCard(chat: chat, thought: thought) { link in
                                    jump(to: link, proxy: proxy)
                                }
                                .id(thought.id)
                            }
                        }
                        .padding(16)
                    } else {
                        ContentUnavailableView("This chat was deleted", systemImage: "trash")
                    }
                }
                .onChange(of: focused) { _, link in
                    guard let link, link.chatID == chatID else { return }
                    withAnimation { proxy.scrollTo(link.thoughtID, anchor: .top) }
                }
            }
            .navigationTitle(store.chat(chatID)?.title ?? "Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { otherChat },
                set: { if $0 == nil { focused = nil } }
            )) { target in
                ChatMemoryView(chatID: target.chatID)
            }
        }
    }

    /// A linked thought in another chat opens that chat on top.
    private var otherChat: OtherChat? {
        guard let focused, focused.chatID != chatID else { return nil }
        return OtherChat(chatID: focused.chatID)
    }

    private struct OtherChat: Identifiable {
        let chatID: UUID
        var id: UUID { chatID }
    }

    private func jump(to link: ConversationStore.ThoughtLink, proxy: ScrollViewProxy) {
        focused = link
    }
}

/// One thought process: the request, the thinking, the actions, the answer,
/// and links to the thoughts before and after.
private struct ThoughtCard: View {
    let chat: ChatRecord
    let thought: ThoughtRecord
    let onJump: (ConversationStore.ThoughtLink) -> Void

    @State private var store = ConversationStore.shared
    @State private var showThinking = false

    var body: some View {
        let link = ConversationStore.ThoughtLink(chatID: chat.id, thoughtID: thought.id)
        let neighbours = store.neighbours(of: link)
        VStack(alignment: .leading, spacing: 10) {
            Text(thought.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(thought.request)
                .font(.system(size: 15, weight: .semibold))

            if !thought.reasoning.isEmpty {
                DisclosureGroup(isExpanded: $showThinking) {
                    Text(thought.reasoning)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Thought process", systemImage: "brain")
                        .font(.system(size: 13, weight: .medium))
                }
                .tint(.secondary)
            }

            if !thought.actions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(thought.actions, id: \.self) { action in
                        Label(action, systemImage: "checkmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(thought.answer)
                .font(.system(size: 14))
                .textSelection(.enabled)

            HStack {
                linkButton("Before", systemImage: "chevron.left", target: neighbours.previous)
                Spacer()
                linkButton("After", systemImage: "chevron.right", target: neighbours.next)
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private func linkButton(_ title: String, systemImage: String,
                            target: ConversationStore.ThoughtLink?) -> some View {
        if let target, let found = store.thought(target) {
            Button {
                onJump(target)
            } label: {
                let label = found.chat.id == chat.id ? title : "\(title): \(found.chat.title)"
                if systemImage == "chevron.left" {
                    Label(label, systemImage: systemImage).lineLimit(1)
                } else {
                    HStack(spacing: 4) {
                        Text(label).lineLimit(1)
                        Image(systemName: systemImage)
                    }
                }
            }
            .buttonStyle(.borderless)
        } else {
            Text(title == "Before" ? "First thought" : "Latest thought")
                .foregroundStyle(.tertiary)
        }
    }
}
