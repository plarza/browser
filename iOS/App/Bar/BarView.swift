import BrowserKit
import SwiftUI

/// Along the bottom, over the page: the stack of tabs, the address bar and
/// New Tab, in glass. Scrolling down the page shrinks it to the site's name.
struct BarView: View {
    let browser: Browser
    let bar: Bar
    let pictures: Pictures
    unowned let screen: ScreenActions
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            if bar.isCollapsed {
                Button {
                    bar.isCollapsed = false
                } label: {
                    Text(browser.selected?.site ?? Look.placeholder)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .overlay { PersistRing(tab: browser.selected, width: 2) }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("address", in: glass)
                .padding(.horizontal, 60)
            } else {
                HStack(spacing: 10) {
                    TabStack(browser: browser, bar: bar, pictures: pictures) { screen.openGrid() }
                        .glassEffectID("stack", in: glass)
                    AddressBar(browser: browser, bar: bar, screen: screen)
                        .glassEffectID("address", in: glass)
                    GlassCircle(symbol: "plus", label: "New Tab") { screen.edit(.newTab) }
                        .glassEffectID("new tab", in: glass)
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, bar.isCollapsed ? 0 : 4)
        .animation(Move.animation(), value: bar.isCollapsed)
    }
}

/// A round glass button, like New Tab's.
struct GlassCircle: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// Persist's ring: on the address bar while the tab keeps its session.
struct PersistRing: View {
    let tab: Tab?
    let width: CGFloat

    var body: some View {
        if tab?.persist == true {
            Capsule().strokeBorder(Color.persist, lineWidth: width)
        }
    }
}
