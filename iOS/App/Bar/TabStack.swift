import BrowserKit
import SwiftUI

/// Arc's stack of tabs: small pictures of the tabs, slightly turned, the
/// tab to the left of the one showing at the back and the one showing in
/// front. A swipe between tabs deals them along with the finger. Tapping
/// it opens the grid.
struct TabStack: View {
    let browser: Browser
    let bar: Bar
    let pictures: Pictures
    let open: () -> Void

    var body: some View {
        let tabs = browser.tabs
        let current = browser.index(of: browser.selected) ?? 0
        let position = bar.position ?? CGFloat(current)
        Button(action: open) {
            ZStack {
                ForEach(Array(tabs.enumerated()).filter { abs(CGFloat($0.offset) - position) < 2 }, id: \.element.id) { index, tab in
                    let place = CGFloat(index) - position
                    StackCard(tab: tab, pictures: pictures)
                        .modifier(StackPlace(place: place))
                        .zIndex(Double(place))
                }
            }
            .frame(width: 50, height: 50)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .animation(Move.animation(), value: current)
        .accessibilityLabel("Tabs")
    }
}

/// One tab in the stack: its picture, or until it has one, its icon.
private struct StackCard: View {
    let tab: Tab
    let pictures: Pictures

    var body: some View {
        Color(.systemBackground)
            .overlay(alignment: .top) {
                if let picture = pictures.picture(of: tab) {
                    Image(uiImage: picture).resizable().scaledToFill()
                } else {
                    SiteIcon(url: tab.url).frame(width: 12, height: 12).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22, height: 29)
            .clipShape(.rect(cornerRadius: 5, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 2.5, y: 1)
    }
}

/// Where a card sits in the stack, by its place: -1 at the back, 0 in
/// front, and further out either way dealt off, faded away. Anywhere
/// between, in between, so the stack follows a finger.
@Animatable
private struct StackPlace: ViewModifier {
    var place: CGFloat

    private struct Stop {
        let turn: Double, x: CGFloat, y: CGFloat, opacity: Double
    }

    /// At places -2, -1, 0 and 1.
    private static let stops = [
        Stop(turn: -22, x: -9, y: 3, opacity: 0),
        Stop(turn: -11, x: -4, y: 1.5, opacity: 1),
        Stop(turn: 6, x: 3, y: -1, opacity: 1),
        Stop(turn: 17, x: 10, y: -3, opacity: 0),
    ]

    func body(content: Content) -> some View {
        let along = min(max(place, -2), 1) + 2
        let lower = min(Int(along), 2)
        let from = Self.stops[lower], to = Self.stops[lower + 1]
        let part = along - CGFloat(lower)
        content
            .rotationEffect(.degrees(from.turn + (to.turn - from.turn) * part))
            .offset(x: from.x + (to.x - from.x) * part, y: from.y + (to.y - from.y) * part)
            .opacity(from.opacity + (to.opacity - from.opacity) * part)
    }
}
