import SwiftUI
import UIKit

enum NavigationStyle: String, CaseIterable, Identifiable {
    case icons, labels, compact
    var id: String { rawValue }
    static let storageKey = "conduit.navigation.style"
    var title: String {
        switch self {
        case .icons: "Icons"
        case .labels: "Icons and text"
        case .compact: "Compact line"
        }
    }
}

struct ConduitNavigationBar: View {
    @Binding var selected: AppPage
    let onSettings: () -> Void
    @AppStorage(NavigationStyle.storageKey) private var style = NavigationStyle.icons.rawValue
    @State private var dragLocation: CGFloat?

    private let pages = AppPage.allCases

    var body: some View {
        Group {
            if style == NavigationStyle.compact.rawValue {
                compactBar
            } else {
                iconBar(showText: style == NavigationStyle.labels.rawValue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 3)
    }

    private func iconBar(showText: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(pages) { page in
                Button { choose(page) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: page.symbol)
                            .font(.system(size: 19, weight: selected == page ? .semibold : .regular))
                            .frame(height: 25)
                        if showText {
                            Text(page.rawValue.capitalized)
                                .font(.system(size: 10, weight: selected == page ? .semibold : .regular))
                        }
                    }
                    .foregroundStyle(selected == page ? Color.conduitAccent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: showText ? 48 : 34)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.rawValue.capitalized)
                .accessibilityAddTraits(selected == page ? .isSelected : [])
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 19))
    }

    private var compactBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.35)).frame(height: 3)
                Capsule()
                    .fill(.white)
                    .frame(width: 24, height: 3)
                    .shadow(color: Color.conduitAccent.opacity(0.9), radius: 8)
                    .offset(x: min(max((dragLocation ?? (geometry.size.width - 24)
                        * CGFloat(activeIndex) / CGFloat(max(pages.count - 1, 1))), 0), geometry.size.width - 24))
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .onTapGesture { location in
                let fraction = min(max(location.x / max(geometry.size.width, 1), 0), 1)
                choose(pages[Int((fraction * CGFloat(pages.count - 1)).rounded())])
            }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    dragLocation = min(max(value.location.x - 12, 0), geometry.size.width - 24)
                }
                .onEnded { value in
                    let fraction = min(max(value.location.x / max(geometry.size.width, 1), 0), 1)
                    choose(pages[Int((fraction * CGFloat(pages.count - 1)).rounded())])
                    dragLocation = nil
                })
            .accessibilityLabel("Compact navigation, \(selected.rawValue) selected. Swipe to change page.")
        }
        .frame(height: 20)
        .padding(.horizontal, 17)
        .glassEffect(.regular, in: .capsule)
    }

    private var activeIndex: Int { pages.firstIndex(of: selected) ?? 0 }

    private func choose(_ page: AppPage) {
        guard page != selected || page == .settings else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        if page == .settings { onSettings() }
        else { withAnimation(.easeInOut(duration: 0.2)) { selected = page } }
    }
}
