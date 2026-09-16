import EventKit
import Foundation
import UserNotifications

/// Calendar, reminders and local notifications.
///
/// This is the part of the app that genuinely runs with zero taps. Once the
/// user has granted access, EventKit writes are immediate and silent — no
/// sheet, no confirmation, no hand-off to another app. Anything that promises
/// real automation on iOS is built on these APIs, which is why the tool set
/// leans on them heavily.
@MainActor
final class CalendarTools: ToolProviding {

    private var store: EKEventStore { Permissions.shared.eventStore }

    let specs: [ToolDescriptor] = [
        ToolDescriptor(
            name: "create_event",
            description: "Add an event to the user's calendar. This happens immediately with no "
                + "confirmation once calendar access is granted.",
            params: [
                .required("title", .string, "The event title."),
                .required("start", .string, "Start time in \(DateParsing.expectedFormat). "
                    + "Call get_current_time first if you need to work out a relative time."),
                .optional("end", .string, "End time in \(DateParsing.expectedFormat). "
                    + "Omit to use duration_minutes instead."),
                .optional("duration_minutes", .integer, "Length in minutes when end is not given. "
                    + "Defaults to 60."),
                .optional("all_day", .boolean, "True for an all-day event."),
                .optional("location", .string, "Where the event takes place."),
                .optional("notes", .string, "Longer notes to attach."),
                .optional("alarm_minutes_before", .integer,
                          "Add an alert this many minutes before the start."),
            ],
            friction: .silent,
            category: "calendar"
        ),
        ToolDescriptor(
            name: "find_events",
            description: "List calendar events in a time range. Use this to answer questions about "
                + "the user's schedule and before scheduling anything, so you do not double-book.",
            params: [
                .required("start", .string, "Range start in \(DateParsing.expectedFormat)."),
                .required("end", .string, "Range end in \(DateParsing.expectedFormat)."),
                .optional("query", .string, "Only return events whose title or location contains this."),
            ],
            friction: .silent,
            category: "calendar"
        ),
        ToolDescriptor(
            name: "check_availability",
            description: "Check whether the user is free in a time range. Returns any conflicting "
                + "events. Prefer this over find_events when the question is simply free or busy.",
            params: [
                .required("start", .string, "Start in \(DateParsing.expectedFormat)."),
                .required("end", .string, "End in \(DateParsing.expectedFormat)."),
            ],
            friction: .silent,
            category: "calendar"
        ),
        ToolDescriptor(
            name: "delete_event",
            description: "Delete a calendar event by its id. Get ids from find_events. "
                + "Confirm with the user in your reply before deleting anything you are unsure about.",
            params: [
                .required("event_id", .string, "The event_id returned by find_events."),
            ],
            friction: .silent,
            category: "calendar"
        ),
        ToolDescriptor(
            name: "create_reminder",
            description: "Add a reminder to the user's Reminders list. Immediate, no confirmation.",
            params: [
                .required("title", .string, "What to be reminded about."),
                .optional("due", .string, "When it is due, in \(DateParsing.expectedFormat)."),
                .optional("notes", .string, "Extra detail."),
                .optional("priority", .string, "Priority level.",
                          allowedValues: ["none", "low", "medium", "high"]),
            ],
            friction: .silent,
            category: "reminders"
        ),
        ToolDescriptor(
            name: "find_reminders",
            description: "List the user's incomplete reminders, so you can answer what is on their list.",
            params: [
                .optional("include_completed", .boolean, "Also include finished reminders."),
            ],
            friction: .silent,
            category: "reminders"
        ),
        ToolDescriptor(
            name: "complete_reminder",
            description: "Mark a reminder as done. Get ids from find_reminders.",
            params: [
                .required("reminder_id", .string, "The reminder_id returned by find_reminders."),
            ],
            friction: .silent,
            category: "reminders"
        ),
        ToolDescriptor(
            name: "schedule_notification",
            description: "Schedule a local notification from Conduit at a specific time. Use this "
                + "for nudges that are not really calendar events, such as reminding the user to "
                + "call someone back in an hour.",
            params: [
                .required("title", .string, "The notification title."),
                .required("at", .string, "When to fire, in \(DateParsing.expectedFormat)."),
                .optional("body", .string, "Secondary line of text."),
            ],
            friction: .silent,
            category: "notifications"
        ),
    ]

    func run(_ name: String, arguments: ArgumentValue) async -> ToolOutcome {
        switch name {
        case "create_event": return await createEvent(arguments)
        case "find_events": return await findEvents(arguments)
        case "check_availability": return await checkAvailability(arguments)
        case "delete_event": return await deleteEvent(arguments)
        case "create_reminder": return await createReminder(arguments)
        case "find_reminders": return await findReminders(arguments)
        case "complete_reminder": return await completeReminder(arguments)
        case "schedule_notification": return await scheduleNotification(arguments)
        default: return .failure(name, "CalendarTools cannot handle \(name).")
        }
    }

    // MARK: - Events

    private func createEvent(_ args: ArgumentValue) async -> ToolOutcome {
        guard let title = args.string("title"), !title.isEmpty else {
            return .badArgument("create_event", "title", "the event title")
        }
        guard let start = DateParsing.parse(args.string("start")) else {
            return .badArgument("create_event", "start", DateParsing.expectedFormat)
        }
        guard await Permissions.shared.canWriteCalendar() else {
            return .denied("create_event", "Calendars")
        }

        let allDay = args.bool("all_day") ?? false
        let end: Date
        if let explicit = DateParsing.parse(args.string("end")) {
            guard explicit > start else {
                return .failure("create_event",
                                "The end time is not after the start time. "
                                    + "Check both values and call create_event again.")
            }
            end = explicit
        } else {
            let minutes = args.int("duration_minutes") ?? (allDay ? 24 * 60 : 60)
            end = start.addingTimeInterval(TimeInterval(minutes * 60))
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        event.location = args.string("location")
        event.notes = args.string("notes")

        guard let calendar = store.defaultCalendarForNewEvents else {
            return .failure("create_event",
                            "There is no default calendar to write to. The user may need to enable "
                                + "a calendar in Settings.")
        }
        event.calendar = calendar

        if let minutesBefore = args.int("alarm_minutes_before") {
            event.addAlarm(EKAlarm(relativeOffset: TimeInterval(-minutesBefore * 60)))
        }

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return .failure("create_event", "The calendar refused to save the event: "
                + error.localizedDescription)
        }

        return .success("create_event",
                        "Added \(title) on \(DateParsing.display(start, includeTime: !allDay))",
                        detail: [
                            "event_id": event.eventIdentifier ?? "unknown",
                            "title": title,
                            "start": DateParsing.iso(start),
                            "end": DateParsing.iso(end),
                            "calendar": calendar.title,
                        ])
    }

    private struct EventSummary {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let location: String?
        let allDay: Bool
    }

    private func fetchEvents(from start: Date, to end: Date) async -> [EventSummary]? {
        guard await Permissions.shared.canReadCalendar() else { return nil }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .map {
                EventSummary(
                    id: $0.eventIdentifier ?? "",
                    title: $0.title ?? "Untitled",
                    start: $0.startDate ?? .distantPast,
                    end: $0.endDate ?? .distantPast,
                    location: $0.location,
                    allDay: $0.isAllDay
                )
            }
    }

    private func findEvents(_ args: ArgumentValue) async -> ToolOutcome {
        guard let start = DateParsing.parse(args.string("start")) else {
            return .badArgument("find_events", "start", DateParsing.expectedFormat)
        }
        guard let end = DateParsing.parse(args.string("end")) else {
            return .badArgument("find_events", "end", DateParsing.expectedFormat)
        }
        // Read needs full access; a write-only grant cannot list events, and
        // saying so plainly is more useful than an empty list that reads as
        // "nothing scheduled".
        guard var events = await fetchEvents(from: start, to: end) else {
            return .failure("find_events",
                            "Reading the calendar needs full access, which has not been granted. "
                                + "Conduit can still add events. The user can change this in "
                                + "Settings, under Privacy and Security, Calendars.")
        }

        if let query = args.string("query")?.lowercased(), !query.isEmpty {
            events = events.filter {
                $0.title.lowercased().contains(query)
                    || ($0.location?.lowercased().contains(query) ?? false)
            }
        }

        guard !events.isEmpty else {
            return .success("find_events", "Nothing scheduled in that range",
                            detail: ["event_count": "0",
                                     "range": "\(DateParsing.iso(start)) to \(DateParsing.iso(end))"])
        }

        let described = events.prefix(25).map { event -> String in
            let when = event.allDay
                ? DateParsing.display(event.start, includeTime: false) + " (all day)"
                : "\(DateParsing.iso(event.start)) to \(DateParsing.iso(event.end))"
            var line = "\(event.title) | \(when) | event_id: \(event.id)"
            if let location = event.location, !location.isEmpty { line += " | at \(location)" }
            return line
        }.joined(separator: "\n")

        return .success("find_events",
                        "\(events.count) event\(events.count == 1 ? "" : "s") found",
                        detail: ["event_count": String(events.count), "events": described])
    }

    private func checkAvailability(_ args: ArgumentValue) async -> ToolOutcome {
        guard let start = DateParsing.parse(args.string("start")) else {
            return .badArgument("check_availability", "start", DateParsing.expectedFormat)
        }
        guard let end = DateParsing.parse(args.string("end")) else {
            return .badArgument("check_availability", "end", DateParsing.expectedFormat)
        }
        guard let events = await fetchEvents(from: start, to: end) else {
            return .failure("check_availability",
                            "Checking availability needs full calendar access, which has not been granted.")
        }
        // All-day events are excluded: a birthday or a holiday marks the whole
        // day busy and would make every slot look taken.
        let conflicts = events.filter { !$0.allDay }
        guard !conflicts.isEmpty else {
            return .success("check_availability", "Free in that window",
                            detail: ["free": "true"])
        }
        let described = conflicts.map {
            "\($0.title) \(DateParsing.iso($0.start)) to \(DateParsing.iso($0.end))"
        }.joined(separator: "; ")
        return .success("check_availability",
                        "Busy: \(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s")",
                        detail: ["free": "false", "conflicts": described])
    }

    private func deleteEvent(_ args: ArgumentValue) async -> ToolOutcome {
        guard let id = args.string("event_id"), !id.isEmpty else {
            return .badArgument("delete_event", "event_id", "an id from find_events")
        }
        guard await Permissions.shared.canReadCalendar() else {
            return .denied("delete_event", "Calendars")
        }
        guard let event = store.event(withIdentifier: id) else {
            return .failure("delete_event",
                            "No event with id \(id). Call find_events again to get current ids; "
                                + "they change when an event is edited.")
        }
        let title = event.title ?? "the event"
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            return .failure("delete_event", "The calendar refused to delete it: "
                + error.localizedDescription)
        }
        return .success("delete_event", "Deleted \(title)", detail: ["deleted_title": title])
    }

    // MARK: - Reminders

    private func createReminder(_ args: ArgumentValue) async -> ToolOutcome {
        guard let title = args.string("title"), !title.isEmpty else {
            return .badArgument("create_reminder", "title", "what to be reminded about")
        }
        guard await Permissions.shared.canUseReminders() else {
            return .denied("create_reminder", "Reminders")
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            return .failure("create_reminder", "There is no default Reminders list to write to.")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = args.string("notes")
        reminder.calendar = calendar

        switch args.string("priority")?.lowercased() {
        case "high": reminder.priority = 1
        case "medium": reminder.priority = 5
        case "low": reminder.priority = 9
        default: reminder.priority = 0
        }

        if let due = DateParsing.parse(args.string("due")) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
            // A due date alone does not notify anyone; Reminders only alerts
            // when the reminder also has an alarm.
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            return .failure("create_reminder", "Reminders refused to save it: "
                + error.localizedDescription)
        }

        var detail = ["reminder_id": reminder.calendarItemIdentifier, "title": title]
        if let due = DateParsing.parse(args.string("due")) { detail["due"] = DateParsing.iso(due) }
        return .success("create_reminder", "Reminder added: \(title)", detail: detail)
    }

    /// `fetchReminders` is callback-based with no async overload, so it is
    /// bridged here. The callback can fire on a background queue, hence the
    /// hop back to the main actor at the call site.
    private func fetchReminders(includeCompleted: Bool) async -> [EKReminder] {
        let predicate = includeCompleted
            ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                    ending: nil,
                                                    calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func findReminders(_ args: ArgumentValue) async -> ToolOutcome {
        guard await Permissions.shared.canUseReminders() else {
            return .denied("find_reminders", "Reminders")
        }
        let includeCompleted = args.bool("include_completed") ?? false
        let reminders = await fetchReminders(includeCompleted: includeCompleted)
        guard !reminders.isEmpty else {
            return .success("find_reminders", "No reminders", detail: ["reminder_count": "0"])
        }
        let described = reminders.prefix(30).map { reminder -> String in
            var line = reminder.title ?? "Untitled"
            if let due = reminder.dueDateComponents,
               let date = Calendar.current.date(from: due) {
                line += " | due \(DateParsing.iso(date))"
            }
            if reminder.isCompleted { line += " | completed" }
            line += " | reminder_id: \(reminder.calendarItemIdentifier)"
            return line
        }.joined(separator: "\n")
        return .success("find_reminders",
                        "\(reminders.count) reminder\(reminders.count == 1 ? "" : "s")",
                        detail: ["reminder_count": String(reminders.count), "reminders": described])
    }

    private func completeReminder(_ args: ArgumentValue) async -> ToolOutcome {
        guard let id = args.string("reminder_id"), !id.isEmpty else {
            return .badArgument("complete_reminder", "reminder_id", "an id from find_reminders")
        }
        guard await Permissions.shared.canUseReminders() else {
            return .denied("complete_reminder", "Reminders")
        }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return .failure("complete_reminder",
                            "No reminder with id \(id). Call find_reminders to get current ids.")
        }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            return .failure("complete_reminder", "Reminders refused to update it: "
                + error.localizedDescription)
        }
        return .success("complete_reminder", "Completed: \(reminder.title ?? "reminder")",
                        detail: ["title": reminder.title ?? ""])
    }

    // MARK: - Notifications

    private func scheduleNotification(_ args: ArgumentValue) async -> ToolOutcome {
        guard let title = args.string("title"), !title.isEmpty else {
            return .badArgument("schedule_notification", "title", "the notification title")
        }
        guard let fireAt = DateParsing.parse(args.string("at")) else {
            return .badArgument("schedule_notification", "at", DateParsing.expectedFormat)
        }
        guard fireAt > Date() else {
            return .failure("schedule_notification",
                            "That time is in the past. Call get_current_time and pick a future time.")
        }
        guard await Permissions.shared.canPostNotifications() else {
            return .denied("schedule_notification", "Notifications")
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let body = args.string("body") { content.body = body }
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireAt
        )
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            return .failure("schedule_notification", "Could not schedule it: "
                + error.localizedDescription)
        }
        return .success("schedule_notification",
                        "Will notify you at \(DateParsing.display(fireAt))",
                        detail: ["at": DateParsing.iso(fireAt), "title": title])
    }
}
