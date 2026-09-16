import SwiftUI

/// Directions without the chat: from, to, travel mode, saved places, recents.
///
/// Routing and turn-by-turn guidance are Apple Maps' job. This page resolves
/// the two ends exactly (or, with no signal, hands Maps the names to search in
/// its offline areas) and opens Maps. See `DirectionsService`.
struct DirectionsView: View {
    @State private var store = PlacesStore.shared
    @State private var connectivity = Connectivity.shared
    @AppStorage("conduit.directions.mode") private var modeRaw = TravelMode.driving.rawValue

    @State private var from = ""
    @State private var to = ""
    @State private var isWorking = false
    @State private var status: String?
    @State private var suggestions: [String] = []
    @State private var suggestionField: Field = .to
    @State private var editing: SavedPlace?
    @State private var showingOfflineHelp = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case from, to }

    private var mode: TravelMode { TravelMode(rawValue: modeRaw) ?? .driving }

    var body: some View {
        NavigationStack {
            Form {
                if !connectivity.isOnline { offlineSection }
                routeSection
                placesSection
                if !store.recents.isEmpty { recentsSection }
                Section {
                    Button {
                        showingOfflineHelp = true
                    } label: {
                        Label("Using directions without a signal", systemImage: "arrow.down.circle")
                    }
                }
            }
            .navigationTitle("Directions")
            .sheet(item: $editing) { place in
                PlaceEditor(place: place) { await store.save($0) }
            }
            .sheet(isPresented: $showingOfflineHelp) {
                OfflineMapsHelp()
            }
            // Places saved without a signal get their exact location as soon
            // as one is available.
            .task(id: connectivity.isOnline) {
                if connectivity.isOnline { await store.pinUnpinnedPlaces() }
            }
        }
    }

    // MARK: - Sections

    private var offlineSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No signal")
                        .font(.headline)
                    Text("Directions still work in areas you've downloaded in Apple Maps. "
                        + "Saved places go straight to their stored location.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var routeSection: some View {
        Section {
            HStack {
                Image(systemName: "location.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                TextField("Current location", text: $from)
                    .focused($focused, equals: .from)
                    .textContentType(.fullStreetAddress)
                    .submitLabel(.next)
                    .onSubmit { focused = .to }
                if !from.isEmpty {
                    clearButton { from = "" }
                }
            }
            HStack {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 26)
                TextField("Where to? Address or saved place", text: $to)
                    .focused($focused, equals: .to)
                    .textContentType(.fullStreetAddress)
                    .submitLabel(.go)
                    .onSubmit { go() }
                if !to.isEmpty {
                    clearButton { to = "" }
                }
            }
            Picker("Travel mode", selection: $modeRaw) {
                ForEach(TravelMode.allCases) { option in
                    Image(systemName: option.symbol)
                        .accessibilityLabel(option.label)
                        .tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Button {
                go()
            } label: {
                HStack {
                    Spacer()
                    if isWorking {
                        ProgressView()
                    } else {
                        Label("Get directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.headline)
                    }
                    Spacer()
                }
            }
            .disabled(to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)

            if let status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(suggestions, id: \.self) { option in
                Button {
                    apply(option)
                } label: {
                    Label(option, systemImage: "mappin")
                        .font(.subheadline)
                }
            }
        }
    }

    private var placesSection: some View {
        Section("Saved places") {
            ForEach(store.places) { place in
                Button {
                    to = place.name
                    go()
                } label: {
                    PlaceRow(place: place)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.delete(place)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editing = place
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
            ForEach(missingDefaults, id: \.self) { name in
                Button {
                    editing = SavedPlace(name: name, address: "")
                } label: {
                    Label("Add \(name)", systemImage: name == "Home" ? "house" : "briefcase")
                }
            }
            Button {
                editing = SavedPlace(name: "", address: "")
            } label: {
                Label("Add a place", systemImage: "plus")
            }
        }
    }

    private var recentsSection: some View {
        Section {
            ForEach(store.recents) { trip in
                Button {
                    from = trip.from ?? ""
                    to = trip.to
                    modeRaw = trip.mode.rawValue
                    go()
                } label: {
                    RecentRow(trip: trip)
                }
            }
        } header: {
            HStack {
                Text("Recent")
                Spacer()
                Button("Clear") { store.clearRecents() }
                    .font(.caption)
                    .textCase(nil)
            }
        }
    }

    private var missingDefaults: [String] {
        ["Home", "Work"].filter { store.place(named: $0) == nil }
    }

    private func clearButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear")
    }

    // MARK: - Actions

    private func go() {
        let destination = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty, !isWorking else { return }
        let origin = from
        let travel = mode
        focused = nil
        isWorking = true
        status = nil
        suggestions = []

        Task {
            let outcome = await DirectionsService.open(from: origin, to: destination, mode: travel)
            isWorking = false
            switch outcome {
            case .opened(_, _, let exact):
                status = exact
                    ? nil
                    : "No signal, so Maps is searching its offline maps for these places. "
                        + "Check it picked the right ones."
            case .unresolved(let role, let query, let options):
                suggestionField = role == "destination" ? .to : .from
                suggestions = options
                status = options.isEmpty
                    ? "Couldn't find the \(role) \u{201C}\(query)\u{201D}. Add the suburb and postcode."
                    : "More than one place could be the \(role) \u{201C}\(query)\u{201D}. Pick one:"
            case .failed(let reason):
                status = reason
            }
        }
    }

    private func apply(_ option: String) {
        switch suggestionField {
        case .to: to = option
        case .from: from = option
        }
        suggestions = []
        go()
    }
}

// MARK: - Rows

private struct PlaceRow: View {
    let place: SavedPlace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(place.resolvedAddress ?? place.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !place.isPinned {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Exact location not saved yet")
            }
        }
    }

    private var symbol: String {
        switch place.name.lowercased() {
        case "home": "house.fill"
        case "work": "briefcase.fill"
        default: "mappin.circle.fill"
        }
    }
}

private struct RecentRow: View {
    let trip: RecentTrip

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: trip.mode.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.to)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("from \(trip.from ?? "current location") · \(trip.date.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Editing a place

private struct PlaceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var place: SavedPlace
    @State private var isSaving = false
    @State private var savedUnpinned = false
    private let originalAddress: String
    private let onSave: @MainActor (SavedPlace) async -> SavedPlace

    init(place: SavedPlace, onSave: @escaping @MainActor (SavedPlace) async -> SavedPlace) {
        _place = State(initialValue: place)
        originalAddress = place.address
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, such as Home", text: $place.name)
                    TextField("Full address, with suburb and postcode", text: $place.address, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                } footer: {
                    Text("Save while you have a signal and the exact location is stored, "
                        + "so directions to this place work offline too.")
                }
                if savedUnpinned {
                    Section {
                        Label("Saved, but the exact location couldn't be found yet. It will be "
                            + "tried again next time you have a signal. Adding the suburb and "
                            + "postcode helps.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(place.name.isEmpty ? "New place" : place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(savedUnpinned ? "Close" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
        }
    }

    private var canSave: Bool {
        !place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !place.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        var toSave = place
        toSave.name = toSave.name.trimmingCharacters(in: .whitespacesAndNewlines)
        toSave.address = toSave.address.trimmingCharacters(in: .whitespacesAndNewlines)
        // A different address makes the stored location wrong.
        if toSave.address != originalAddress {
            toSave.latitude = nil
            toSave.longitude = nil
            toSave.resolvedAddress = nil
        }
        isSaving = true
        Task {
            let stored = await onSave(toSave)
            isSaving = false
            if stored.isPinned {
                dismiss()
            } else {
                place = stored
                savedUnpinned = true
            }
        }
    }
}

// MARK: - Offline help

private struct OfflineMapsHelp: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Once, while you have a signal") {
                    step(1, "Open Apple Maps.")
                    step(2, "Tap your profile picture or initials in the search area.")
                    step(3, "Tap Offline Maps, then Download New Map.")
                    step(4, "Resize the box to cover everywhere you travel, then tap Download.")
                    step(5, "In Directions, save Home, Work and other regular places.")
                }
                Section("Then, with no signal") {
                    Text("Directions from Conduit open in Maps with turn-by-turn guidance, as long "
                        + "as both ends are inside a downloaded area. Public transport times may "
                        + "still need a signal.")
                    Text("Saved places go to their stored location, so they never depend on a search.")
                }
                Section {
                    Button {
                        if let url = URL(string: "maps://") {
                            Task { _ = await ComposePresenter.open(url) }
                        }
                    } label: {
                        Label("Open Apple Maps", systemImage: "map")
                    }
                }
            }
            .navigationTitle("Offline directions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        Label(text, systemImage: "\(number).circle.fill")
    }
}
