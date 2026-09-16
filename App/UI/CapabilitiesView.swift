import SwiftUI

/// The honest capability list, in the app rather than only in the README.
///
/// This screen exists because the most likely way this app disappoints someone
/// is a mismatch of expectations, not a bug. iOS decides what an app may do,
/// and the answer is the same whether the model runs on the device or in a
/// datacentre. Saying that plainly, once, in the product itself, is worth more
/// than any amount of prompt engineering after the fact.
struct CapabilitiesView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let text: String
        let note: String?
    }

    private let immediate: [Item] = [
        Item(text: "Create, find, move and delete calendar events", note: nil),
        Item(text: "Check whether you are free at a given time", note: nil),
        Item(text: "Create and complete reminders", note: nil),
        Item(text: "Schedule its own notifications as nudges", note: nil),
        Item(text: "Look up contacts and remember nicknames", note: "\"mum\" means a real person, once you say who"),
        Item(text: "Put text on the clipboard", note: nil),
        Item(text: "Tell you the time, date and time zone", note: nil),
        Item(text: "Search the web, read pages and check the weather",
             note: "With the globe switch on. Full web search needs a free Tavily key on the "
                 + "Online page; without one it searches Wikipedia."),
        Item(text: "Research a person or topic across many pages",
             note: "Turn on Research from the plus button. It searches every combination of your "
                 + "keywords, checks each page is about the same subject before using it, and never "
                 + "collects addresses, phone numbers or details about someone's children."),
        Item(text: "Custom personalities",
             note: "Each has its own voice, goal, connectors, model and colour. Hard-working ones "
                 + "think first, take more steps, and can write up to three drafts of an answer, "
                 + "one after another."),
    ]

    private let oneTap: [Item] = [
        Item(text: "Text messages",
             note: "Conduit fills in the recipient and the message. iOS requires you to tap send."),
        Item(text: "Emails",
             note: "Same: composed and ready, but you tap send."),
        Item(text: "Phone and FaceTime calls",
             note: "Conduit starts the call; iOS asks you to confirm."),
    ]

    private let handoff: [Item] = [
        Item(text: "Run one of your Shortcuts by name",
             note: "This is the real escape hatch. Anything Shortcuts can do, Conduit can trigger."),
        Item(text: "Directions in Apple Maps, from anywhere to anywhere",
             note: "Works with no signal in areas you have downloaded in Apple Maps. "
                 + "Saved places such as Home keep their exact location."),
        Item(text: "Open any app, Music, or a page in Safari", note: nil),
    ]

    private let impossible: [Item] = [
        Item(text: "Send a message, email or call without you tapping",
             note: "No third-party iOS app can. This is not a Conduit limitation."),
        Item(text: "Read your received texts, emails or notifications",
             note: "iOS exposes none of it to apps."),
        Item(text: "Answer, decline or hang up a call", note: nil),
        Item(text: "Create a Shortcut", note: "It can only run ones you already made."),
        Item(text: "Set an alarm, change a Focus mode, toggle Wi-Fi or Bluetooth",
             note: "Make a Shortcut that does it, and Conduit can run that."),
        Item(text: "Read or control other apps", note: nil),
        Item(text: "Log in to websites or fill in forms",
             note: "It reads public pages only, in a private browser with no cookies."),
    ]

    var body: some View {
        List {
            Section {
                Text("iOS, not the model, decides what an app is allowed to do. Running Qwen on "
                    + "your phone makes Conduit private and available offline — it does not "
                    + "unlock anything the sandbox forbids.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            group("Happens immediately", systemImage: "checkmark.circle.fill",
                  tint: .green, items: immediate)

            group("Prepared, then you tap", systemImage: "hand.tap.fill",
                  tint: .orange, items: oneTap)

            group("Hands off to another app", systemImage: "arrow.up.forward.app.fill",
                  tint: .blue, items: handoff)

            group("Not possible", systemImage: "xmark.circle.fill",
                  tint: .red, items: impossible)

            Section {
                Text("If you want something in the last list, build a Shortcut for it once and "
                    + "give it a clear name. Then ask Conduit to run that shortcut by name, and "
                    + "it will work from then on.")
                    .font(.system(size: 14))
            } header: {
                Text("Getting past the limits")
            }
        }
        .navigationTitle("Capabilities")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func group(_ title: String, systemImage: String, tint: Color,
                       items: [Item]) -> some View {
        Section {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(tint)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text)
                            .font(.system(size: 15))
                        if let note = item.note {
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(title)
        }
    }
}
