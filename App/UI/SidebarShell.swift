import SwiftUI

/// The app's pages, reached from the sidebar.
enum AppPage: String, CaseIterable, Identifiable {
    case chat, directions, online, models, capabilities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .directions: "Directions"
        case .online: "Online"
        case .models: "Models"
        case .capabilities: "What Conduit can do"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .directions: "arrow.triangle.turn.up.right.diamond"
        case .online: "globe"
        case .models: "cpu"
        case .capabilities: "checklist"
        }
    }
}

/// A pull tab on the left edge that slides out a column of page icons.
///
/// Hidden by default so the chat keeps the full width of the phone. It opens
/// from the tab or a swipe in from the left edge, and closes on a tap outside,
/// a swipe back, or picking a page. The view only draws the tab, a thin swipe
/// strip and (when open) the column, so everything else stays tappable.
struct SidebarOverlay: View {
    @Binding var page: AppPage
    @Binding var isOpen: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if isOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { isOpen = false }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                rail
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                edgeSwipeStrip
                pullTab
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isOpen)
    }

    // MARK: - Closed

    private var pullTab: some View {
        VStack {
            Spacer()
            Button {
                isOpen = true
            } label: {
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 22, height: 64)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 11))
            .offset(x: -5)
            .accessibilityLabel("Open menu")
            Spacer()
            Spacer()
        }
    }

    /// A narrow strip along the left edge for the swipe-in gesture. It stops
    /// above the command bar so it never takes taps meant for the model chip.
    private var edgeSwipeStrip: some View {
        Color.clear
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .padding(.bottom, 110)
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { value in
                        if value.translation.width > 50 { isOpen = true }
                    }
            )
            .accessibilityHidden(true)
    }

    // MARK: - Open

    private var rail: some View {
        VStack {
            Spacer()
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 6) {
                    ForEach(AppPage.allCases) { item in
                        railButton(item)
                    }
                }
                .padding(6)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
            .padding(.leading, 10)
            Spacer()
            Spacer()
        }
        .gesture(
            DragGesture(minimumDistance: 16)
                .onEnded { value in
                    if value.translation.width < -40 { isOpen = false }
                }
        )
    }

    private func railButton(_ item: AppPage) -> some View {
        let selected = item == page
        return Button {
            page = item
            isOpen = false
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 48, height: 48)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.accentColor.opacity(0.18))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
