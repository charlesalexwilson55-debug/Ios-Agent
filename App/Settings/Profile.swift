import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the user tells Conduit about themselves.
struct UserProfile: Codable, Equatable {
    var name = ""
    var pronouns = ""
    var about = ""
    var work = ""
    var interests = ""
    var goals = ""
    var answerStyle = ""
}

/// A social or media account whose data export was imported.
struct ImportedAccount: Codable, Identifiable, Hashable {
    var id: String { service }
    var service: String
    var imported: Date
    var characters: Int
    /// Hashtags, accounts and topics that come up most, worked out in code.
    var highlights: String
}

/// The user's profile and imported accounts. The profile goes into every
/// prompt; account data is searched like a library.
@MainActor
@Observable
final class ProfileStore {
    static let shared = ProfileStore()

    static let services = [
        "Instagram", "TikTok", "X", "Facebook", "Snapchat", "Spotify", "YouTube", "Reddit",
        "Pinterest", "LinkedIn", "Other",
    ]

    private(set) var profile = UserProfile()
    private(set) var accounts: [ImportedAccount] = []
    private(set) var importingService: String?

    private static let profileKey = "conduit.profile"
    private static let accountsKey = "conduit.profile.accounts"
    private static let fieldLimit = 400

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.profileKey),
           let saved = try? JSONDecoder().decode(UserProfile.self, from: data) {
            profile = saved
        }
        if let data = defaults.data(forKey: Self.accountsKey),
           let saved = try? JSONDecoder().decode([ImportedAccount].self, from: data) {
            accounts = saved
        }
    }

    func save(_ updated: UserProfile) {
        profile = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: Self.profileKey)
        }
    }

    /// The section added to the system prompt, or nil when nothing is filled in.
    var promptSection: String? {
        func clip(_ text: String) -> String {
            String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.fieldLimit))
        }
        var lines: [String] = []
        if !clip(profile.name).isEmpty { lines.append("Name: \(clip(profile.name))") }
        if !clip(profile.pronouns).isEmpty { lines.append("Pronouns: \(clip(profile.pronouns))") }
        if !clip(profile.about).isEmpty { lines.append("About them: \(clip(profile.about))") }
        if !clip(profile.work).isEmpty { lines.append("Work or study: \(clip(profile.work))") }
        if !clip(profile.interests).isEmpty { lines.append("Interests: \(clip(profile.interests))") }
        if !clip(profile.goals).isEmpty { lines.append("Goals: \(clip(profile.goals))") }
        if !clip(profile.answerStyle).isEmpty { lines.append("How they like answers: \(clip(profile.answerStyle))") }
        let highlights = accounts.map { "\($0.service): \($0.highlights)" }.filter { !$0.hasSuffix(": ") }
        if !highlights.isEmpty {
            lines.append("From their accounts: " + String(highlights.joined(separator: "; ").prefix(Self.fieldLimit)))
        }
        guard !lines.isEmpty else { return nil }
        return "# About the user\n" + lines.joined(separator: "\n")
            + "\nUse this to make answers fit them. Do not bring it up unless it is relevant."
    }

    // MARK: - Account exports

    static func collection(for service: String) -> String { "account:\(service.lowercased())" }

    /// Reads a data export (a ZIP, a folder, or a single file) and indexes it.
    func importExport(from url: URL, service: String) async throws {
        importingService = service
        defer { importingService = nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let text = try await Task.detached(priority: .userInitiated) { () -> String in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isFolder { return try TextExtractor.folderText(url) }
            if url.pathExtension.lowercased() == "zip" { return try TextExtractor.archiveText(url) }
            let raw = try await TextExtractor.text(from: url)
            return url.pathExtension.lowercased() == "json" ? JSONText.flatten(raw) : raw
        }.value
        guard !text.isEmpty else { throw TextExtractor.ExtractError.empty }

        let collection = Self.collection(for: service)
        try await KnowledgeIndex.shared.remove(collection: collection)
        try await KnowledgeIndex.shared.add(id: "\(collection)/export", source: .profile,
                                            collection: collection, title: "\(service) data", text: text)
        let account = ImportedAccount(service: service, imported: Date(), characters: text.count,
                                      highlights: Self.highlights(in: text))
        accounts.removeAll { $0.service == service }
        accounts.append(account)
        persistAccounts()
    }

    /// Adds a plain list, such as YouTube subscriptions, as account data.
    func importList(_ items: [String], service: String, heading: String) async throws {
        guard !items.isEmpty else { throw TextExtractor.ExtractError.empty }
        let text = heading + ":\n" + items.joined(separator: "\n")
        let collection = Self.collection(for: service)
        try await KnowledgeIndex.shared.remove(collection: collection)
        try await KnowledgeIndex.shared.add(id: "\(collection)/export", source: .profile, collection: collection,
                                            title: "\(service) \(heading.lowercased())", text: text)
        let account = ImportedAccount(service: service, imported: Date(), characters: text.count,
                                      highlights: "subscribed to " + items.prefix(8).joined(separator: ", "))
        accounts.removeAll { $0.service == service }
        accounts.append(account)
        persistAccounts()
    }

    func removeAccount(_ service: String) async {
        accounts.removeAll { $0.service == service }
        persistAccounts()
        try? await KnowledgeIndex.shared.remove(collection: Self.collection(for: service))
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
    }

    /// The hashtags and accounts that come up most.
    static func highlights(in text: String) -> String {
        func top(_ pattern: String, count: Int) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            var tally: [String: Int] = [:]
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let found = Range(match.range, in: text) else { return }
                tally[text[found].lowercased(), default: 0] += 1
            }
            return tally.filter { $0.value > 1 }
                .sorted { $0.value > $1.value }
                .prefix(count)
                .map { $0.key }
        }
        var parts: [String] = []
        let tags = top(#"#[A-Za-z][A-Za-z0-9_]{2,30}"#, count: 8)
        if !tags.isEmpty { parts.append("often uses " + tags.joined(separator: " ")) }
        let people = top(#"@[A-Za-z0-9_.]{3,30}"#, count: 6)
        if !people.isEmpty { parts.append("often interacts with " + people.joined(separator: " ")) }
        return parts.joined(separator: ", ")
    }
}

extension TextExtractor {
    /// Every readable file in a folder, such as an unzipped data export.
    static func folderText(_ url: URL, limit: Int = characterLimit) throws -> String {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw ExtractError.empty }
        var parts: [String] = []
        var total = 0
        for case let file as URL in walker where total < limit {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) < 20_000_000 else { continue }
            let ext = file.pathExtension.lowercased()
            var body: String?
            switch ext {
            case "json":
                body = (try? Data(contentsOf: file)).flatMap { decode($0) }.map { JSONText.flatten($0) }
            case "html", "htm":
                body = (try? Data(contentsOf: file)).flatMap { decode($0) }.map { HTMLText.plain($0) }
            case "txt", "csv", "md":
                body = (try? Data(contentsOf: file)).flatMap { decode($0) }
            default:
                continue
            }
            guard let text = body?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let relative = file.path.replacingOccurrences(of: url.path, with: "")
            parts.append("[\(relative)]\n\(text)")
            total += text.count
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Settings > You.
struct ProfileSettingsView: View {
    @State private var store = ProfileStore.shared
    @State private var draft = ProfileStore.shared.profile
    @State private var importService: String?
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var showingHelp: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                TextField("Pronouns", text: $draft.pronouns)
                TextField("Work or study", text: $draft.work)
            } header: {
                Text("Your personality")
            } footer: {
                Text("Conduit reads this before every answer, so keep it to what helps.")
            }
            Section("About you") {
                TextField("A few lines about you", text: $draft.about, axis: .vertical)
                    .lineLimit(2...6)
                TextField("Interests", text: $draft.interests, axis: .vertical)
                    .lineLimit(1...4)
                TextField("Goals", text: $draft.goals, axis: .vertical)
                    .lineLimit(1...4)
                TextField("How you like answers, e.g. short and direct", text: $draft.answerStyle, axis: .vertical)
                    .lineLimit(1...4)
            }

            Section {
                ForEach(ProfileStore.services, id: \.self) { service in
                    accountRow(service)
                }
            } header: {
                Text("Your accounts")
            } footer: {
                Text("Instagram, TikTok and most other apps no longer let other apps read a personal "
                    + "account. Instead, download your data from the app (tap ? for how), then import the ZIP, "
                    + "folder or file here. It is read and kept only on this phone.")
            }
        }
        .onChange(of: draft) { _, updated in store.save(updated) }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.zip, .folder, .json, .html, .plainText, .commaSeparatedText]) { result in
            guard case .success(let url) = result, let service = importService else { return }
            Task {
                do {
                    try await store.importExport(from: url, service: service)
                } catch {
                    importError = "\(service): \(error.localizedDescription)"
                }
            }
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert(showingHelp.map { "Get your \($0) data" } ?? "", isPresented: Binding(
            get: { showingHelp != nil },
            set: { if !$0 { showingHelp = nil } }
        )) {
            Button("OK", role: .cancel) { showingHelp = nil }
        } message: {
            Text(showingHelp.map(Self.howToExport) ?? "")
        }
    }

    private func accountRow(_ service: String) -> some View {
        let account = store.accounts.first { $0.service == service }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(service)
                if let account {
                    Text("Imported \(account.imported.formatted(date: .abbreviated, time: .omitted))"
                        + (account.highlights.isEmpty ? "" : " \u{00B7} \(account.highlights)"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if store.importingService == service {
                ProgressView()
            } else {
                Button {
                    showingHelp = service
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                Button(account == nil ? "Import" : "Update") {
                    importService = service
                    showingImporter = true
                }
                .buttonStyle(.bordered)
                if account != nil {
                    Button {
                        Task { await store.removeAccount(service) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)
                }
            }
        }
    }

    static func howToExport(_ service: String) -> String {
        switch service {
        case "Instagram":
            return "In Instagram: Settings > Accounts Centre > Your information and permissions > Download "
                + "your information. Choose JSON. When the download is ready, save the ZIP to Files."
        case "TikTok":
            return "In TikTok: Profile > menu > Settings and privacy > Account > Download your data. Choose "
                + "JSON, request it, then download the file to Files."
        case "X":
            return "In X: Settings > Your account > Download an archive of your data. Save the ZIP to Files."
        case "Facebook":
            return "In Facebook: Settings > Accounts Centre > Your information and permissions > Download "
                + "your information. Choose JSON."
        case "Snapchat":
            return "In Snapchat: Settings > My Data. Choose JSON, then download the ZIP from the email link."
        case "Spotify":
            return "On spotify.com: Account > Privacy settings > Download your data. Save the ZIP to Files."
        case "YouTube":
            return "Use takeout.google.com and pick YouTube, or connect Google in Settings > Connectors."
        case "Reddit":
            return "On reddit.com: Settings > Privacy > Request data. Save the ZIP to Files."
        case "Pinterest":
            return "In Pinterest: Settings > Privacy and data > Request your data."
        case "LinkedIn":
            return "In LinkedIn: Settings > Data privacy > Get a copy of your data."
        default:
            return "Import any ZIP, folder, JSON, CSV, HTML or text file with information about you."
        }
    }
}
