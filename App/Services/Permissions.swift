import Contacts
import EventKit
import Foundation
import UserNotifications

/// Centralised permission handling.
///
/// Two rules drive the design:
///
/// 1. **Ask lazily, at the point of use.** Prompting for calendar, reminders,
///    contacts, mic and notifications on first launch produces five modal
///    dialogs before the user has typed anything, and a reflexive "Don't
///    Allow" on all five. Each tool requests only what it needs, the first
///    time it needs it.
///
/// 2. **Never re-prompt after a denial.** iOS shows the system dialog exactly
///    once; every later request returns the cached denial without any UI. A
///    retry loop on a denied permission is therefore an infinite loop that the
///    user cannot see or escape, so `ToolOutcome.denied` tells the model not
///    to retry and to explain the Settings path instead.
@MainActor
final class Permissions {
    static let shared = Permissions()

    /// One store for the whole app. `EKEventStore` is expensive to build and
    /// holds the access grant; creating one per call also drops change
    /// notifications.
    let eventStore = EKEventStore()
    let contactStore = CNContactStore()

    private init() {}

    // MARK: - Calendar

    /// Conduit asks for full access rather than write-only. Write-only cannot
    /// answer "am I free at 3pm", which is half of what anyone wants from a
    /// calendar agent. Write-only remains in Info.plist so a user who granted
    /// only that still gets working event creation.
    func calendarAccess() async -> EKAuthorizationStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined:
            _ = try? await eventStore.requestFullAccessToEvents()
            return EKEventStore.authorizationStatus(for: .event)
        default:
            return status
        }
    }

    func canReadCalendar() async -> Bool {
        await calendarAccess() == .fullAccess
    }

    func canWriteCalendar() async -> Bool {
        let status = await calendarAccess()
        return status == .fullAccess || status == .writeOnly
    }

    // MARK: - Reminders

    /// Reminders has no write-only tier; it is full access or nothing.
    func canUseReminders() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            _ = try? await eventStore.requestFullAccessToReminders()
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        }
        return status == .fullAccess
    }

    // MARK: - Contacts

    /// On iOS 18+ the user can grant access to a *subset* of contacts. That
    /// reports as `.limited`, and a lookup that finds nothing may mean "not
    /// shared" rather than "no such person" — worth distinguishing in the
    /// message back to the model so it does not insist the contact is absent.
    func contactsAccess() async -> CNAuthorizationStatus {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .notDetermined else { return status }
        _ = try? await contactStore.requestAccess(for: .contacts)
        return CNContactStore.authorizationStatus(for: .contacts)
    }

    func canReadContacts() async -> Bool {
        let status = await contactsAccess()
        if status == .authorized { return true }
        if #available(iOS 18.0, *) { return status == .limited }
        return false
    }

    var contactsAreLimited: Bool {
        guard #available(iOS 18.0, *) else { return false }
        return CNContactStore.authorizationStatus(for: .contacts) == .limited
    }

    // MARK: - Notifications

    func canPostNotifications() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    // MARK: - Reporting

    /// Snapshot for the capability screen. Read-only: it must never trigger a
    /// prompt, or opening that screen would fire every dialog at once.
    struct Snapshot {
        var calendar: String
        var reminders: String
        var contacts: String
        var notifications: String
    }

    func snapshot() async -> Snapshot {
        let calendar = EKEventStore.authorizationStatus(for: .event)
        let reminders = EKEventStore.authorizationStatus(for: .reminder)
        let contacts = CNContactStore.authorizationStatus(for: .contacts)
        let notifications = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
        return Snapshot(
            calendar: Self.describe(calendar),
            reminders: Self.describe(reminders),
            contacts: Self.describe(contacts),
            notifications: Self.describe(notifications)
        )
    }

    private static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .fullAccess: return "Full access"
        case .writeOnly: return "Write only"
        @unknown default: return "Unknown"
        }
    }

    private static func describe(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorized: return "Full access"
        default:
            if #available(iOS 18.0, *), status == .limited { return "Selected contacts only" }
            return "Unknown"
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not asked yet"
        case .denied: return "Denied"
        case .authorized: return "Allowed"
        case .provisional: return "Quiet delivery"
        case .ephemeral: return "Temporary"
        @unknown default: return "Unknown"
        }
    }
}
