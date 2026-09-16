import SwiftUI

/// The Personalities page: the saved personalities, which one is in use,
/// and a plus to make a new one.
struct PersonasView: View {
    /// Set by the plus menu's "New personality" row, so the editor opens
    /// straight away.
    @Binding var startNew: Bool

    @Environment(ModelCatalog.self) private var catalog
    @State private var store = PersonaStore.shared
    @State private var editing: Persona?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(name: "Conduit", subtitle: "The standard assistant", color: nil,
                        selected: store.selectedID == nil) {
                        store.select(nil)
                    }
                } footer: {
                    Text("Pick a personality here or from the plus button in the chat bar.")
                }

                Section("Your personalities") {
                    if store.personas.isEmpty {
                        Text("None yet. Tap + to make one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.personas) { persona in
                        row(name: persona.name,
                            subtitle: subtitle(for: persona),
                            color: persona.color,
                            selected: store.selectedID == persona.id) {
                            store.select(persona.id)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { store.delete(persona.id) }
                            Button("Edit") { editing = persona }
                                .tint(.gray)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = persona }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                store.delete(persona.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Personalities")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = Persona()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New personality")
                }
            }
            // A sheet rather than a pushed page: the app's round menu button
            // sits where a pushed page's Back button would be.
            .sheet(item: $editing) { persona in
                PersonaEditor(persona: persona, isNew: !store.personas.contains(where: { $0.id == persona.id }))
                    .environment(catalog)
            }
            .onAppear(perform: openNewIfAsked)
            .onChange(of: startNew) { _, _ in openNewIfAsked() }
        }
    }

    private func openNewIfAsked() {
        guard startNew else { return }
        startNew = false
        editing = Persona()
    }

    private func subtitle(for persona: Persona) -> String {
        let title = persona.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = persona.effort == .normal ? "" : persona.effort.title
        return [title, effort].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    private func row(
        name: String,
        subtitle: String,
        color: Color?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(color ?? Color.secondary.opacity(0.3))
                    .frame(width: 26, height: 26)
                    .overlay {
                        if color == nil {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "Untitled" : name)
                        .foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The page for making or changing a personality.
struct PersonaEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ModelCatalog.self) private var catalog

    @State private var draft: Persona
    @State private var customColor: Color
    private let isNew: Bool

    init(persona: Persona, isNew: Bool) {
        _draft = State(initialValue: persona)
        _customColor = State(initialValue: persona.color)
        self.isNew = isNew
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("For example, Scout", text: $draft.name)
                        .textInputAutocapitalization(.words)
                }

                Section("Job title") {
                    TextField("For example, Research assistant", text: $draft.jobTitle)
                        .textInputAutocapitalization(.words)
                }

                Section("Colour") {
                    colourGrid
                    ColorPicker("Custom colour", selection: $customColor, supportsOpacity: false)
                        .onChange(of: customColor) { _, color in
                            draft.colorHex = color.hexString
                        }
                }

                Section {
                    TextField("Warm and to the point. Uses plain words and a bit of humour.",
                              text: $draft.personality, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Personality")
                } footer: {
                    Text("How it talks and behaves.")
                }

                Section {
                    TextField("Find out everything useful about the people and companies I ask about.",
                              text: $draft.goal, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Main goal")
                }

                connectorsSection
                modelSection
                effortSection

                if !isNew {
                    Section {
                        Button("Delete personality", role: .destructive) {
                            PersonaStore.shared.delete(draft.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New personality" : "Edit personality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        PersonaStore.shared.save(draft)
                        if isNew { PersonaStore.shared.select(draft.id) }
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    // MARK: - Sections

    private var colourGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
            ForEach(Persona.palette) { swatch in
                let selected = draft.colorHex.caseInsensitiveCompare(swatch.hex) == .orderedSame
                Button {
                    draft.colorHex = swatch.hex
                } label: {
                    Circle()
                        .fill(Color(hex: swatch.hex) ?? .accentColor)
                        .frame(width: 36, height: 36)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(3)
                        .overlay {
                            Circle().strokeBorder(selected ? Color.primary.opacity(0.5) : .clear, lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private var connectorsSection: some View {
        Section {
            TextField("For example: calendar, web, maps", text: $draft.connectors, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Connector.allCases) { connector in
                        let used = Connector.matches(in: draft.connectors).contains(connector)
                        Button {
                            addConnector(connector)
                        } label: {
                            Text(connector.title)
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(used ? draft.color.opacity(0.25) : Color.secondary.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(used)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Main connectors")
        } footer: {
            Text(connectorSummary)
        }
    }

    private var connectorSummary: String {
        let matched = Connector.matches(in: draft.connectors)
        if draft.allowedToolNames == nil {
            return "Uses every connector. Name some, such as calendar or web, to limit it to those. "
                + "These are Conduit's built-in connectors: MCP servers cannot run inside an iPhone app."
        }
        return "Uses: " + matched.map(\.title).joined(separator: ", ")
            + ". The clock and calculator are always available."
    }

    private var modelSection: some View {
        Section {
            HStack {
                TextField("Keep the current model", text: $draft.model)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !catalog.models.isEmpty {
                    Menu {
                        ForEach(catalog.models) { model in
                            Button(model.displayName) { draft.model = model.displayName }
                        }
                        Button("Keep the current model") { draft.model = "" }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .accessibilityLabel("Choose from the models on this phone")
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text(modelFooter)
        }
    }

    private var modelFooter: String {
        let name = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "Leave empty to use whichever model is loaded."
        }
        if ModelMatcher.match(name, in: catalog.models) == nil {
            return "No model on this phone matches that name yet, so the current model will be used."
        }
        return "Switching to this personality loads that model, which takes a little while."
    }

    private var effortSection: some View {
        Section {
            Picker("Work rate", selection: $draft.effort) {
                ForEach(Persona.Effort.allCases) { effort in
                    Text(effort.title).tag(effort)
                }
            }
            .pickerStyle(.segmented)
            Stepper(value: $draft.drafts, in: 1...Persona.maxDrafts) {
                Text(draft.drafts == 1 ? "1 draft per answer" : "\(draft.drafts) drafts per answer")
            }
        } header: {
            Text("How hard it works")
        } footer: {
            Text(effortFooter)
        }
    }

    private var effortFooter: String {
        let drafts: String
        if draft.drafts == 1 {
            drafts = "Writes one answer."
        } else {
            drafts = "Writes \(draft.drafts) answers to a question, then keeps the best parts. The "
                + "phone runs one at a time, so this takes about \(draft.drafts + 1) times as long. "
                + "Phone actions are never done twice."
        }
        return draft.effort.detail + " " + drafts
    }

    private func addConnector(_ connector: Connector) {
        let current = draft.connectors.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.connectors = current.isEmpty ? connector.keyword : current + ", " + connector.keyword
    }
}

/// Finds the installed model a personality names.
enum ModelMatcher {
    static func match(_ name: String, in models: [DiscoveredModel]) -> DiscoveredModel? {
        let wanted = normalised(name)
        guard !wanted.isEmpty else { return nil }
        if let exact = models.first(where: { normalised($0.displayName) == wanted }) {
            return exact
        }
        return models.first { model in
            let have = normalised(model.displayName)
            let folder = normalised(model.directory.lastPathComponent)
            return have.contains(wanted) || folder.contains(wanted)
                || (!have.isEmpty && wanted.contains(have))
        }
    }

    private static func normalised(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
