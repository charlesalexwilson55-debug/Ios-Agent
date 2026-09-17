import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import UIKit

/// The Google services Conduit can connect to.
enum GoogleService: String, CaseIterable, Identifiable, Codable {
    case gmail, calendar, drive, tasks, contacts, youtube

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: "Gmail"
        case .calendar: "Google Calendar"
        case .drive: "Drive, Docs and Sheets"
        case .tasks: "Google Tasks"
        case .contacts: "Google Contacts"
        case .youtube: "YouTube"
        }
    }

    var symbol: String {
        switch self {
        case .gmail: "envelope"
        case .calendar: "calendar"
        case .drive: "folder"
        case .tasks: "checklist"
        case .contacts: "person.2"
        case .youtube: "play.rectangle"
        }
    }

    var detail: String {
        switch self {
        case .gmail: "Search and read mail, and save drafts. Conduit never sends mail on its own."
        case .calendar: "See and add events on your Google calendar."
        case .drive: "Search your Drive and read Docs, Sheets, Slides, PDFs and text files."
        case .tasks: "See and add Google Tasks."
        case .contacts: "Look up people in your Google contacts."
        case .youtube: "Search YouTube, and add your subscriptions to your profile."
        }
    }

    var scopes: [String] {
        let base = "https://www.googleapis.com/auth/"
        switch self {
        case .gmail: return [base + "gmail.readonly", base + "gmail.compose"]
        case .calendar: return [base + "calendar.events"]
        case .drive: return [base + "drive.readonly"]
        case .tasks: return [base + "tasks"]
        case .contacts: return [base + "contacts.readonly"]
        case .youtube: return [base + "youtube.readonly"]
        }
    }
}

/// The connected Google account: sign-in, tokens and which services are on.
///
/// Sign-in is Google's own page in a secure browser sheet, using OAuth with
/// PKCE, so Conduit never sees the password and needs no secret of its own.
/// The refresh token is kept in the Keychain.
@MainActor
@Observable
final class GoogleAccount {
    static let shared = GoogleAccount()

    enum AuthError: LocalizedError {
        case noClientID
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noClientID: "Google sign-in is not set up yet. Add a Google client ID first."
            case .cancelled: "Sign-in was cancelled."
            case .failed(let why): "Google sign-in failed: \(why)"
            }
        }
    }

    private(set) var email: String?
    private(set) var grantedScopes: Set<String> = []
    private(set) var enabled: Set<GoogleService> = Set(GoogleService.allCases)
    private(set) var connecting = false

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private let anchor = WindowAnchor()

    private static let emailKey = "conduit.google.email"
    private static let scopesKey = "conduit.google.scopes"
    private static let enabledKey = "conduit.google.enabled"
    static let clientIDKey = "conduit.google.clientID"
    private static let secretAccount = "google-refresh-token"

    init() {
        let defaults = UserDefaults.standard
        email = defaults.string(forKey: Self.emailKey)
        grantedScopes = Set(defaults.stringArray(forKey: Self.scopesKey) ?? [])
        if let saved = defaults.stringArray(forKey: Self.enabledKey) {
            enabled = Set(saved.compactMap(GoogleService.init(rawValue:)))
        }
    }

    var isConnected: Bool { email != nil && MCPSecrets.read(account: Self.secretAccount) != nil }

    /// The client ID from Settings, or the one built into the app.
    var clientID: String? {
        let typed = UserDefaults.standard.string(forKey: Self.clientIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !typed.isEmpty { return typed }
        let bundled = (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return bundled.isEmpty || bundled.hasPrefix("$(") ? nil : bundled
    }

    func setClientID(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.clientIDKey)
    }

    /// Services that are switched on and were granted at sign-in.
    var usableServices: [GoogleService] {
        guard isConnected else { return [] }
        return GoogleService.allCases.filter { service in
            enabled.contains(service) && service.scopes.allSatisfy { grantedScopes.contains($0) }
        }
    }

    func setEnabled(_ service: GoogleService, _ on: Bool) {
        if on { enabled.insert(service) } else { enabled.remove(service) }
        UserDefaults.standard.set(enabled.map(\.rawValue), forKey: Self.enabledKey)
    }

    // MARK: - Sign-in

    /// Opens Google's sign-in for every switched-on service.
    func connect() async throws {
        guard let clientID else { throw AuthError.noClientID }
        connecting = true
        defer { connecting = false }

        let scheme = Self.redirectScheme(for: clientID)
        let redirect = "\(scheme):/oauth2redirect"
        let verifier = Self.randomString(64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomString(24)
        let services = enabled.isEmpty ? Set(GoogleService.allCases) : enabled
        let scopes = ["openid", "email", "profile"] + services.flatMap(\.scopes)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw AuthError.failed("bad sign-in address") }

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: AuthError.failed(error?.localizedDescription ?? "no response"))
                }
            }
            session.presentationContextProvider = anchor
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AuthError.failed("the sign-in sheet could not open"))
            }
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw AuthError.failed("the reply did not match this sign-in")
        }
        if let problem = items.first(where: { $0.name == "error" })?.value {
            throw AuthError.failed(problem)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.failed("Google sent no code")
        }

        let token = try await Self.tokenRequest([
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = token["refresh_token"] as? String else {
            throw AuthError.failed("Google did not allow offline access")
        }
        MCPSecrets.save(refresh, account: Self.secretAccount)
        store(token)
        grantedScopes = Set(((token["scope"] as? String) ?? "").split(separator: " ").map(String.init))
        UserDefaults.standard.set(Array(grantedScopes), forKey: Self.scopesKey)

        let profile = try await get("https://www.googleapis.com/oauth2/v3/userinfo")
        email = (profile["email"] as? String) ?? "Google account"
        UserDefaults.standard.set(email, forKey: Self.emailKey)
    }

    func disconnect() async {
        if let refresh = MCPSecrets.read(account: Self.secretAccount),
           var components = URLComponents(string: "https://oauth2.googleapis.com/revoke") {
            components.queryItems = [URLQueryItem(name: "token", value: refresh)]
            if let url = components.url {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                _ = try? await URLSession.shared.data(for: request)
            }
        }
        MCPSecrets.save("", account: Self.secretAccount)
        accessToken = nil
        accessExpiry = .distantPast
        email = nil
        grantedScopes = []
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        UserDefaults.standard.removeObject(forKey: Self.scopesKey)
    }

    // MARK: - Requests

    /// A valid access token, refreshed when needed.
    func token() async throws -> String {
        if let accessToken, accessExpiry > Date().addingTimeInterval(60) { return accessToken }
        guard let clientID, let refresh = MCPSecrets.read(account: Self.secretAccount) else {
            throw AuthError.failed("Google is not connected. Connect it in Settings > Connectors.")
        }
        let token = try await Self.tokenRequest([
            "client_id": clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ])
        store(token)
        guard let accessToken else { throw AuthError.failed("no access token") }
        return accessToken
    }

    func get(_ address: String, query: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await raw(address, query: query)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func post(_ address: String, json: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: json)
        let data = try await raw(address, method: "POST", body: body, contentType: "application/json")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func raw(_ address: String, query: [String: String] = [:], method: String = "GET",
             body: Data? = nil, contentType: String? = nil) async throws -> Data {
        guard var components = URLComponents(string: address) else { throw AuthError.failed("bad address") }
        if !query.isEmpty {
            components.queryItems = (components.queryItems ?? [])
                + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw AuthError.failed("bad address") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 { accessToken = nil }
            throw AuthError.failed(Self.errorMessage(data, status: status))
        }
        return data
    }

    private func store(_ token: [String: Any]) {
        if let access = token["access_token"] as? String {
            accessToken = access
            let seconds = (token["expires_in"] as? Double) ?? Double((token["expires_in"] as? Int) ?? 3600)
            accessExpiry = Date().addingTimeInterval(seconds)
        }
    }

    // MARK: - Helpers

    private static func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AuthError.failed(errorMessage(data, status: status))
        }
        return json
    }

    private static func errorMessage(_ data: Data, status: Int) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "error \(status)"
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let description = json["error_description"] as? String { return description }
        if let error = json["error"] as? String { return error }
        return "error \(status)"
    }

    /// Google's iOS clients redirect to the client ID written backwards.
    static func redirectScheme(for clientID: String) -> String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { characters[Int($0) % characters.count] })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Tells the sign-in sheet which window to appear over.
final class WindowAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // iOS asks on the main thread.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
