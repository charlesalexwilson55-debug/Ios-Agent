import Contacts
import Foundation
import UIKit

/// Contacts, messages, calls and email.
///
/// Note the friction labels. `find_contact` is silent, but every tool that
/// *reaches* another person requires the user to confirm in a system sheet.
/// That boundary is imposed by iOS and is the single most important thing for
/// the model to represent accurately, so the descriptions say so in the text
/// the model actually reads.
@MainActor
final class PeopleTools: ToolProviding {

    /// User-taught nicknames, persisted across launches.
    ///
    /// iOS exposes no public way to read the "me" card's relationships, so
    /// "text Mum" cannot be resolved the way Siri resolves it. Rather than
    /// guessing at a contact named Mum, the model asks once and records the
    /// answer here, which is both honest and permanent.
    private enum AliasStore {
        private static let key = "conduit.personAliases"

        static func all() -> [String: String] {
            UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        }

        static func resolve(_ alias: String) -> String? {
            all()[alias.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)]
        }

        static func remember(alias: String, contactName: String) {
            var current = all()
            current[alias.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)] = contactName
            UserDefaults.standard.set(current, forKey: key)
        }
    }

    let specs: [ToolDescriptor] = [
        ToolDescriptor(
            name: "find_contact",
            description: "Look up a person in the user's contacts and return their phone numbers "
                + "and email addresses. Call this before send_message, place_call or send_email "
                + "whenever you were given a name rather than a number, so you send to the right person.",
            params: [
                .required("name", .string, "A name, partial name or saved nickname to search for."),
            ],
            friction: .silent,
            category: "people"
        ),
        ToolDescriptor(
            name: "remember_person_alias",
            description: "Record that a nickname refers to a specific contact, for example that "
                + "'mum' means 'Jane Wilson'. Use this after the user tells you who a nickname "
                + "refers to, so you never have to ask again.",
            params: [
                .required("alias", .string, "The nickname the user says, such as mum, dad, or the boss."),
                .required("contact_name", .string, "The full contact name the nickname refers to."),
            ],
            friction: .silent,
            category: "people"
        ),
        ToolDescriptor(
            name: "send_message",
            description: "Open a text message pre-filled with your recipient and body. "
                + "IMPORTANT: this does NOT send the message. iOS requires the user to tap send "
                + "in the sheet that appears, and there is no way for an app to bypass that. "
                + "Report it as drafted, never as sent, unless the result says the user sent it.",
            params: [
                .required("to", .string, "Phone number, contact name, or saved nickname."),
                .required("body", .string, "The message text, written in the user's voice."),
            ],
            friction: .requiresConfirmation,
            category: "people"
        ),
        ToolDescriptor(
            name: "place_call",
            description: "Start a phone call. iOS shows a confirmation and then leaves Conduit "
                + "for the Phone app. You cannot answer, decline or hang up calls; only start one.",
            params: [
                .required("to", .string, "Phone number, contact name, or saved nickname."),
                .optional("facetime", .boolean, "Use FaceTime instead of a cellular call."),
            ],
            friction: .leavesApp,
            category: "people"
        ),
        ToolDescriptor(
            name: "send_email",
            description: "Open an email pre-filled with recipients, subject and body. "
                + "IMPORTANT: this does NOT send the email; the user must tap send in the sheet. "
                + "You also cannot read the user's inbox — iOS gives apps no access to received mail.",
            params: [
                .required("to", .string, "Recipient email, contact name, or nickname. "
                    + "Separate several recipients with commas."),
                .required("subject", .string, "The subject line."),
                .required("body", .string, "The email body, written in the user's voice."),
                .optional("cc", .string, "Comma-separated addresses to copy."),
            ],
            friction: .requiresConfirmation,
            category: "people"
        ),
    ]

    func run(_ name: String, arguments: ArgumentValue) async -> ToolOutcome {
        switch name {
        case "find_contact": return await findContact(arguments)
        case "remember_person_alias": return rememberAlias(arguments)
        case "send_message": return await sendMessage(arguments)
        case "place_call": return await placeCall(arguments)
        case "send_email": return await sendEmail(arguments)
        default: return .failure(name, "PeopleTools cannot handle \(name).")
        }
    }

    // MARK: - Contacts

    private struct Match {
        let displayName: String
        let phones: [String]
        let emails: [String]
    }

    private func search(_ query: String) async -> [Match] {
        guard await Permissions.shared.canReadContacts() else { return [] }
        let resolved = AliasStore.resolve(query) ?? query
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: resolved)
        let contacts = (try? Permissions.shared.contactStore
            .unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []

        return contacts.map { contact in
            let name = CNContactFormatter.string(from: contact, style: .fullName)
                ?? [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }.joined(separator: " ")
            return Match(
                displayName: name.isEmpty ? contact.organizationName : name,
                phones: contact.phoneNumbers.map { $0.value.stringValue },
                emails: contact.emailAddresses.map { $0.value as String }
            )
        }
    }

    private func findContact(_ args: ArgumentValue) async -> ToolOutcome {
        guard let query = args.string("name"), !query.isEmpty else {
            return .badArgument("find_contact", "name", "a name to search for")
        }
        guard await Permissions.shared.canReadContacts() else {
            return .denied("find_contact", "Contacts")
        }
        let matches = await search(query)
        guard !matches.isEmpty else {
            // A "limited access" grant makes absence ambiguous, and the model
            // should not tell the user a person does not exist when the real
            // cause is that the contact was simply not shared with the app.
            let hint = Permissions.shared.contactsAreLimited
                ? " The user granted access to only selected contacts, so this person may exist "
                    + "but not be shared with Conduit. Ask the user to share them, or ask for the number."
                : " Ask the user for the phone number or email address."
            return .failure("find_contact", "No contact matched \(query)." + hint)
        }

        let described = matches.prefix(5).map { match in
            var parts = [match.displayName]
            if !match.phones.isEmpty { parts.append("phones: " + match.phones.joined(separator: ", ")) }
            if !match.emails.isEmpty { parts.append("emails: " + match.emails.joined(separator: ", ")) }
            return parts.joined(separator: " | ")
        }.joined(separator: "\n")

        return .success("find_contact",
                        matches.count == 1
                            ? "Found \(matches[0].displayName)"
                            : "Found \(matches.count) contacts matching \(query)",
                        detail: [
                            "match_count": String(matches.count),
                            "matches": described,
                            "guidance": matches.count > 1
                                ? "More than one match. Ask the user which person they meant "
                                    + "rather than guessing."
                                : "Single match; safe to use.",
                        ])
    }

    private func rememberAlias(_ args: ArgumentValue) -> ToolOutcome {
        guard let alias = args.string("alias"), !alias.isEmpty else {
            return .badArgument("remember_person_alias", "alias", "the nickname to record")
        }
        guard let contactName = args.string("contact_name"), !contactName.isEmpty else {
            return .badArgument("remember_person_alias", "contact_name", "the full contact name")
        }
        AliasStore.remember(alias: alias, contactName: contactName)
        return .success("remember_person_alias",
                        "Noted that \(alias) means \(contactName)",
                        detail: ["alias": alias, "contact_name": contactName])
    }

    // MARK: - Recipient resolution

    private enum Resolution {
        case number(String, label: String)
        case ambiguous(String)
        case notFound(String)
    }

    /// Resolves free text to a phone number.
    ///
    /// Ambiguity is returned rather than resolved by picking the first match.
    /// Guessing here means messaging the wrong person, which is the single
    /// worst failure this app can produce, so it always hands the choice back.
    private func resolvePhone(_ raw: String) async -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Already a dialable number: digits plus the usual punctuation.
        let dialable = CharacterSet(charactersIn: "+0123456789 ()-.")
        if !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ dialable.contains($0) }),
           trimmed.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil {
            return .number(trimmed, label: trimmed)
        }

        let matches = await search(trimmed)
        let withPhones = matches.filter { !$0.phones.isEmpty }
        if withPhones.isEmpty { return .notFound(trimmed) }
        if withPhones.count > 1 {
            let names = withPhones.prefix(5).map(\.displayName).joined(separator: ", ")
            return .ambiguous(names)
        }
        let match = withPhones[0]
        if match.phones.count > 1 {
            return .ambiguous("\(match.displayName) has several numbers: "
                + match.phones.joined(separator: ", "))
        }
        return .number(match.phones[0], label: match.displayName)
    }

    private func resolveEmail(_ raw: String) async -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return .number(trimmed, label: trimmed) }

        let matches = await search(trimmed)
        let withEmails = matches.filter { !$0.emails.isEmpty }
        if withEmails.isEmpty { return .notFound(trimmed) }
        if withEmails.count > 1 {
            return .ambiguous(withEmails.prefix(5).map(\.displayName).joined(separator: ", "))
        }
        let match = withEmails[0]
        if match.emails.count > 1 {
            return .ambiguous("\(match.displayName) has several addresses: "
                + match.emails.joined(separator: ", "))
        }
        return .number(match.emails[0], label: match.displayName)
    }

    // MARK: - Messaging

    private func sendMessage(_ args: ArgumentValue) async -> ToolOutcome {
        guard let to = args.string("to"), !to.isEmpty else {
            return .badArgument("send_message", "to", "a phone number, contact name or nickname")
        }
        guard let body = args.string("body"), !body.isEmpty else {
            return .badArgument("send_message", "body", "the message text")
        }

        let recipient: String
        let label: String
        switch await resolvePhone(to) {
        case .number(let number, let name):
            recipient = number
            label = name
        case .ambiguous(let candidates):
            return .failure("send_message",
                            "More than one possible recipient for \(to): \(candidates). "
                                + "Ask the user which one, then call send_message again.")
        case .notFound(let query):
            return .failure("send_message",
                            "No contact or number found for \(query). Ask the user for the number, "
                                + "or call find_contact with a different spelling.")
        }

        let result = await ComposePresenter.shared.presentMessage(recipients: [recipient], body: body)
        switch result {
        case .sent:
            return .success("send_message", "Message to \(label) sent",
                            detail: ["recipient": label, "outcome": "sent"])
        case .cancelled:
            return .failure("send_message",
                            "The user dismissed the message without sending it. "
                                + "Do not retry unless they ask; acknowledge and stop.")
        case .unavailable(let why), .failed(let why):
            return .failure("send_message", "Could not open the message composer: \(why)")
        case .savedAsDraft:
            return .staged("send_message", "Message to \(label) saved as a draft",
                           detail: ["recipient": label, "outcome": "draft"])
        }
    }

    private func placeCall(_ args: ArgumentValue) async -> ToolOutcome {
        guard let to = args.string("to"), !to.isEmpty else {
            return .badArgument("place_call", "to", "a phone number, contact name or nickname")
        }

        let number: String
        let label: String
        switch await resolvePhone(to) {
        case .number(let resolved, let name):
            number = resolved
            label = name
        case .ambiguous(let candidates):
            return .failure("place_call",
                            "More than one possible number for \(to): \(candidates). Ask the user which.")
        case .notFound(let query):
            return .failure("place_call", "No contact or number found for \(query).")
        }

        let useFaceTime = args.bool("facetime") ?? false
        // Strip formatting: tel: rejects spaces and parentheses.
        let dialable = number.filter { "+0123456789".contains($0) }
        let scheme = useFaceTime ? "facetime" : "tel"
        guard let url = URL(string: "\(scheme):\(dialable)") else {
            return .failure("place_call", "\(number) is not a dialable number.")
        }
        guard await ComposePresenter.open(url) else {
            return .failure("place_call",
                            "iOS refused to start the call. On a device with no cellular service, "
                                + "try FaceTime instead by passing facetime true.")
        }
        return .staged("place_call",
                       useFaceTime ? "Starting FaceTime with \(label)" : "Calling \(label)",
                       detail: [
                           "recipient": label,
                           "outcome": "handed off to the phone app; iOS asks the user to confirm",
                       ])
    }

    private func sendEmail(_ args: ArgumentValue) async -> ToolOutcome {
        guard let to = args.string("to"), !to.isEmpty else {
            return .badArgument("send_email", "to", "a recipient address, contact name or nickname")
        }
        guard let subject = args.string("subject") else {
            return .badArgument("send_email", "subject", "a subject line")
        }
        guard let body = args.string("body") else {
            return .badArgument("send_email", "body", "the email body")
        }

        var addresses: [String] = []
        var labels: [String] = []
        for piece in to.split(separator: ",").map({ String($0) }) {
            switch await resolveEmail(piece) {
            case .number(let address, let label):
                addresses.append(address)
                labels.append(label)
            case .ambiguous(let candidates):
                return .failure("send_email",
                                "More than one possible address for \(piece): \(candidates). Ask the user which.")
            case .notFound(let query):
                return .failure("send_email", "No email address found for \(query).")
            }
        }

        var ccAddresses: [String] = []
        if let cc = args.string("cc"), !cc.isEmpty {
            for piece in cc.split(separator: ",").map({ String($0) }) {
                if case .number(let address, _) = await resolveEmail(piece) {
                    ccAddresses.append(address)
                }
            }
        }

        let result = await ComposePresenter.shared.presentMail(
            to: addresses, cc: ccAddresses, subject: subject, body: body
        )
        switch result {
        case .sent:
            return .success("send_email", "Email to \(labels.joined(separator: ", ")) sent",
                            detail: ["recipients": labels.joined(separator: ", "), "outcome": "sent"])
        case .cancelled:
            return .failure("send_email",
                            "The user dismissed the email without sending it. Acknowledge and stop.")
        case .savedAsDraft:
            return .staged("send_email", "Email saved as a draft",
                           detail: ["outcome": "draft"])
        case .unavailable(let why):
            // Fall back to mailto:, which can reach Gmail or Outlook when the
            // built-in Mail app has no account configured.
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = addresses.joined(separator: ",")
            components.queryItems = [
                URLQueryItem(name: "subject", value: subject),
                URLQueryItem(name: "body", value: body),
            ]
            if let url = components.url, await ComposePresenter.open(url) {
                return .staged("send_email", "Opened your mail app with the draft",
                               detail: ["outcome": "handed off to an external mail app"])
            }
            return .failure("send_email", "Could not compose an email: \(why)")
        case .failed(let why):
            return .failure("send_email", "Could not compose an email: \(why)")
        }
    }
}
