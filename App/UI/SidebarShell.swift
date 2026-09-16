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

/// A round menu button in the top-left corner that opens a column of page
/// icons beneath it.
///
/// The column is hidden by default so every page keeps the full width of the
/// phone. It opens from the button or a swipe in from the left edge, and
/// closes on the button, a tap outside, a swipe back, or picking a page. The
/// view only draws the button, a thin swipe strip and (when open) the column,
/// so everything else stays tappable.
struct SidebarOverlay: View {
    @Binding var page: AppPage
    @Binding var isOpen: Bool

    private static let buttonSize: CGFloat = 44

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { isOpen = false }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                rail
                    .padding(.top, Self.buttonSize + 12)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                edgeSwipeStrip
            }
            menuButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isOpen)
    }

    private var menuButton: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: isOpen ? "xmark" : "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(.circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(.leading, 16)
        .padding(.top, 2)
        .accessibilityLabel(isOpen ? "Close menu" : "Open menu")
    }

    /// A narrow strip along the left edge for the swipe-in gesture. It stays
    /// clear of the menu button and the command bar.
    private var edgeSwipeStrip: some View {
        Color.clear
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .padding(.top, Self.buttonSize + 16)
            .padding(.bottom, 110)
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { value in
                        if value.translation.width > 50 { isOpen = true }
                    }
            )
            .accessibilityHidden(true)
    }

    private var rail: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 6) {
                ForEach(AppPage.allCases) { item in
                    railButton(item)
                }
            }
            .padding(6)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .padding(.leading, 14)
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
