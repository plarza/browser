import BrowserKit
import SwiftUI
import UIKit

/// The address bar: the site's name. Tapping it brings up the address
/// sheet; a long press, the tab's menu; dragging it sideways, the next
/// tab; dragging it up, the grid.
struct AddressBar: View {
    let browser: Browser
    let bar: Bar
    unowned let screen: ScreenActions

    var body: some View {
        // A tap is the menu's first action; holding brings up the rest.
        Menu {
            if let tab = browser.selected { AddressMenu(tab: tab) }
        } label: {
            name
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .overlay(alignment: .bottom) { LoadingLine(tab: browser.selected) }
                .overlay { PersistRing(tab: browser.selected, width: 2.5) }
                .contentShape(.capsule)
        } primaryAction: {
            screen.edit(.current)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .gesture(AddressBarPan { screen.addressBarPanned($0) })
        .accessibilityLabel("Address")
    }

    /// The site's name; past halfway through a swipe, that of the tab it
    /// is heading for.
    private var name: some View {
        let tab = bar.named ?? browser.selected
        return Text(tab?.site ?? Look.placeholder)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tab?.site == nil ? .secondary : .primary)
            .lineLimit(1)
            .id(tab?.id)
            .transition(.blurReplace)
            .animation(.snappy(duration: 0.26), value: tab?.id)
    }
}

/// A thin line along the address bar's bottom edge shows loading.
private struct LoadingLine: View {
    let tab: Tab?

    var body: some View {
        if let tab, tab.isLoading {
            GeometryReader { box in
                Capsule()
                    .fill(.tint)
                    .frame(width: max(12, box.size.width * tab.progress), height: 2.5)
                    .animation(.easeOut(duration: 0.25), value: tab.progress)
            }
            .frame(height: 2.5)
            .padding(.horizontal, 22)
            .padding(.bottom, 3)
            .transition(.opacity)
        }
    }
}

/// Long press on the address bar.
private struct AddressMenu: View {
    let tab: Tab

    var body: some View {
        if !tab.isPopup {
            Toggle(isOn: Binding { tab.persist } set: { tab.persist = $0 }) {
                Label("Persist", systemImage: "lock")
            }
        }
        Button("Reload", systemImage: "arrow.clockwise") { tab.reload() }
        if let url = tab.url, tab.page == nil {
            Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = url }
            Button("Find on Page", systemImage: "magnifyingglass") {
                tab.webView.findInteraction?.presentFindNavigator(showingReplace: false)
            }
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }
}

/// A drag on the address bar, as UIKit sees it, so the page follows the
/// finger without SwiftUI in between.
private struct AddressBarPan: UIGestureRecognizerRepresentable {
    let panned: (UIPanGestureRecognizer) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        UIPanGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        panned(pan)
    }
}
