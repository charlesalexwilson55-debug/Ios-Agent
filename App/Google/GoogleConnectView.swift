import SwiftUI

/// The Google section of Settings > Connectors: one Connect button, and a
/// switch per service.
struct GoogleConnectSection: View {
    @State private var google = GoogleAccount.shared
    @State private var profile = ProfileStore.shared
    @State private var error: String?
    @State private var showingSetup = false
    @State private var importingSubscriptions = false
    @State private var note: String?

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Text("G")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .red, .yellow, .green],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                    .background { Circle().fill(Color.white) }
                    .overlay { Circle().strokeBorder(.secondary.opacity(0.25)) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Google").font(.headline)
                    Text(google.email ?? "Not connected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if google.connecting {
                    ProgressView()
                } else if google.isConnected {
                    Button("Disconnect", role: .destructive) {
                        Task { await google.disconnect() }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Connect") { connect() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 4)

            ForEach(GoogleService.allCases) { service in
                serviceRow(service)
            }

            if google.usableServices.contains(.youtube) {
                Button {
                    importSubscriptions()
                } label: {
                    HStack {
                        Label("Add my YouTube subscriptions to my profile", systemImage: "person.crop.circle.badge.plus")
                        Spacer()
                        if importingSubscriptions { ProgressView() }
                    }
                }
                .disabled(importingSubscriptions)
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
            if google.clientID != nil {
                Button("Change Google client ID") { showingSetup = true }
                    .font(.footnote)
            }
        } header: {
            Text("Google")
        } footer: {
            Text("You sign in on Google's own page; Conduit never sees your password. Name the service in a "
                + "message to use it, for example \u{201C}find the invoice in my Gmail\u{201D}. Conduit saves "
                + "email drafts but never sends mail itself.")
        }
        .alert("Google", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .sheet(isPresented: $showingSetup) {
            GoogleSetupSheet {
                connect()
            }
        }
    }

    private func serviceRow(_ service: GoogleService) -> some View {
        let granted = service.scopes.allSatisfy { google.grantedScopes.contains($0) }
        return Toggle(isOn: Binding(
            get: { google.enabled.contains(service) },
            set: { google.setEnabled(service, $0) }
        )) {
            HStack(spacing: 10) {
                Image(systemName: service.symbol)
                    .frame(width: 24)
                    .foregroundStyle(Color.conduitAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.title)
                    Text(google.isConnected && !granted && google.enabled.contains(service)
                        ? "Reconnect to allow this" : service.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func connect() {
        guard google.clientID != nil else {
            showingSetup = true
            return
        }
        Task {
            do {
                try await google.connect()
            } catch GoogleAccount.AuthError.cancelled {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func importSubscriptions() {
        importingSubscriptions = true
        Task {
            defer { importingSubscriptions = false }
            do {
                let names = try await GoogleTools.youtubeSubscriptions()
                try await profile.importList(names, service: "YouTube", heading: "Subscribed channels")
                note = "Added \(names.count) YouTube subscriptions to your profile."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The one-time Google Cloud setup, and where the client ID goes.
struct GoogleSetupSheet: View {
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var clientID = GoogleAccount.shared.clientID ?? ""

    private var valid: Bool {
        clientID.trimmingCharacters(in: .whitespaces).hasSuffix(".apps.googleusercontent.com")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Google only lets apps it knows about sign in, so a free Google Cloud client ID "
                        + "is needed once. It takes about five minutes on a computer.")
                }
                Section("Steps") {
                    step(1, "Open console.cloud.google.com and create a project called Conduit.")
                    step(2, "In APIs & Services > Library, enable Gmail API, Google Calendar API, Google "
                        + "Drive API, Google Tasks API, People API and YouTube Data API v3.")
                    step(3, "In Google Auth Platform > Branding, fill in the app name and your email. Under "
                        + "Audience choose External, add your Google address as a test user, then press Publish "
                        + "app so sign-in does not expire every week.")
                    step(4, "In Clients, create a client of type iOS with bundle ID com.charles.conduit.")
                    step(5, "Copy the client ID (it ends in .apps.googleusercontent.com) and paste it below.")
                    Text("When you sign in, Google may warn that the app is unverified. That is expected for "
                        + "a personal app: tap Advanced, then continue.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let link = URL(string: "https://console.cloud.google.com/auth/clients") {
                        Link("Open Google Cloud Console", destination: link)
                    }
                }
                Section {
                    TextField("123456-abc.apps.googleusercontent.com", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Client ID")
                } footer: {
                    Text("A client ID is not a password. It only tells Google which app is asking.")
                }
            }
            .navigationTitle("Set up Google")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save and connect") {
                        GoogleAccount.shared.setClientID(clientID)
                        dismiss()
                        Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            onSaved()
                        }
                    }
                    .disabled(!valid)
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 22, height: 22)
                .background { Circle().fill(Color.conduitAccent.opacity(0.2)) }
            Text(text).font(.subheadline)
        }
    }
}
