import BrowserKit
import SwiftUI

/// Arc's tab stack, the address bar and New Tab, in glass along the
/// bottom. Scrolling down the page shrinks it to the site's name. Dragging
/// the address bar sideways pulls the next tab in; dragging it up shrinks
/// the page into the grid under the finger.
struct BottomBar: View {
    @Environment(Browser.self) private var browser
    @Namespace private var glass
    /// Which way the address bar is being dragged, settled by the first move.
    @State private var axis: Axis?

    var body: some View {
        let _ = browser.revision
        GlassEffectContainer(spacing: 10) {
            if browser.barCollapsed {
                Button {
                    withAnimation(Motion.spring()) { browser.barCollapsed = false }
                } label: {
                    Text(site)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .overlay { persistRing }
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("address", in: glass)
            } else {
                HStack(spacing: 10) {
                    if !browser.tabs.isEmpty {
                        TabStack()
                            .glassEffectID("stack", in: glass)
                    }
                    address
                        .glassEffectID("address", in: glass)
                    GlassCircle(symbol: "plus", label: "New Tab") { browser.edit(.newTab) }
                        .glassEffectID("plus", in: glass)
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, browser.barCollapsed ? 0 : 4)
    }

    private var tab: Tab? { browser.selected }

    private var site: String { AddressLabel.site(tab) }

    @ViewBuilder private var persistRing: some View {
        if tab?.persist == true {
            Capsule().strokeBorder(Color.persist, lineWidth: 2.5)
        }
    }

    private var address: some View {
        AddressLabel(dragging: axis == .horizontal)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .overlay(alignment: .bottom) { progress }
            .overlay { persistRing }
            .contentShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .onTapGesture { browser.edit(tab == nil ? .newTab : .current) }
            .contextMenu { if tab != nil { AddressMenu() } }
            .gesture(swipe)
    }

    @ViewBuilder private var progress: some View {
        if let progress = browser.progress {
            GeometryReader { box in
                Capsule().fill(Color.accentColor)
                    .frame(width: max(12, box.size.width * progress), height: 2.5)
                    .animation(.easeOut(duration: 0.25), value: progress)
            }
            .frame(height: 2.5)
            .padding(.horizontal, 22)
            .padding(.bottom, 3)
            .transition(.opacity)
        }
    }

    /// Sideways: the page follows the finger with the next tab beside it,
    /// as in Safari. Up: the page shrinks towards its card as you go, and
    /// letting go finishes at the finger's speed, or springs back.
    private var swipe: some Gesture {
        // In the window's coordinates: the bar moves as the grid comes, and
        // measuring against it would feed its own movement back in.
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                let x = value.translation.width, y = value.translation.height
                if axis == nil {
                    axis = abs(x) > abs(y) ? .horizontal : (y < 0 && tab != nil ? .vertical : nil)
                    if axis != nil, let tab { browser.snapshot(tab) }
                }
                switch axis {
                case .horizontal:
                    let (previous, next) = browser.neighbours
                    browser.pageOffset = (x > 0 ? previous : next) != nil ? x : x / 4
                case .vertical:
                    browser.gridProgress = min(1, max(0, -y / Self.pull))
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer { axis = nil }
                switch axis {
                case .horizontal:
                    browser.endSwipe(translation: value.translation.width, velocity: value.velocity.width, width: Screen.bounds.width)
                case .vertical:
                    let p = browser.gridProgress
                    let speed = -value.velocity.height / Self.pull
                    if p + speed * 0.15 > 0.4 {
                        browser.showGrid(velocity: p < 1 ? speed / (1 - p) : 0)
                    } else {
                        browser.showPage(velocity: p > 0 ? -speed / p : 0)
                    }
                case nil:
                    break
                }
            }
    }

    /// How far up the finger goes to take the page all the way into the grid.
    static let pull: CGFloat = 320
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

/// Long press on the address bar.
struct AddressMenu: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        if let tab = browser.selected {
            if tab.opener == nil {
                Toggle(isOn: Binding(get: { tab.persist }, set: { tab.persist = $0 })) {
                    Label("Persist", systemImage: "lock")
                }
            }
            Button { tab.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
            if let url = tab.url, tab.internalPage == nil {
                Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
                Button {
                    tab.webView.findInteraction?.presentFindNavigator(showingReplace: false)
                } label: { Label("Find on Page", systemImage: "magnifyingglass") }
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

/// The site's name, or once a swipe is past halfway, the name of the tab
/// it's heading to, trading places with a soft blur.
struct AddressLabel: View {
    @Environment(Browser.self) private var browser
    let dragging: Bool

    var body: some View {
        let _ = browser.revision
        let tab = shown
        Text(Self.site(tab))
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tab?.url == nil && tab?.internalPage == nil ? .secondary : .primary)
            .lineLimit(1)
            .id(tab?.id)
            .transition(.blurReplace)
            .animation(Motion.snappy, value: tab?.id)
    }

    private var shown: Tab? {
        guard dragging else { return browser.selected }
        let half = Screen.bounds.width / 2, (previous, next) = browser.neighbours
        if browser.pageOffset > half, let previous { return previous }
        if browser.pageOffset < -half, let next { return next }
        return browser.selected
    }

    static func site(_ tab: Tab?) -> String {
        guard let tab else { return "Search or enter website name" }
        if let page = tab.internalPage { return page.capitalized }
        guard let host = tab.url?.host else { return "Search or enter website name" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Arc's little stack of tabs: the tab to the left of the one showing at
/// the back, the one showing in front. A swipe between tabs deals them
/// along with the finger. Opens the grid.
struct TabStack: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let _ = browser.revision
        let tabs = browser.tabs
        let current = browser.selected.flatMap { s in tabs.firstIndex { $0 === s } } ?? 0
        // How far along the swipe is, in tabs: towards the left is positive.
        let shift = browser.pageOffset / (Screen.bounds.width + PageArea.gap)
        let near = tabs.indices.filter { abs($0 - current) <= 2 }
        Button {
            browser.showGrid()
        } label: {
            ZStack {
                ForEach(near, id: \.self) { i in
                    let place = CGFloat(i - current) + shift
                    card(tabs[i])
                        .modifier(StackPlace(place: place))
                        .zIndex(Double(place))
                }
            }
            .frame(width: 50, height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tabs")
    }

    private func card(_ tab: Tab) -> some View {
        TabPicture(image: browser.snapshots[tab.id])
            .overlay {
                if browser.snapshots[tab.id] == nil, let icon = Favicons.shared.icon(for: tab.url) {
                    Image(uiImage: icon).resizable().scaledToFit().frame(width: 14, height: 14)
                }
            }
            .frame(width: 26, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
    }
}

/// Where a card sits in the stack, by its place: −1 the back card, 0 the
/// front one, further out faded away; anywhere between, in between.
struct StackPlace: ViewModifier, Animatable {
    var place: CGFloat

    var animatableData: CGFloat {
        get { place }
        set { place = newValue }
    }

    /// Place, turn, x, y, opacity.
    private static let stops: [(CGFloat, Double, CGFloat, CGFloat, Double)] = [
        (-2, -22, -10, 3, 0), (-1, -12, -5, 2, 1), (0, 6, 4, -1, 1), (1, 16, 11, -3, 0),
    ]

    func body(content: Content) -> some View {
        let p = min(max(place, -2), 1)
        let i = min(Int((p + 2).rounded(.down)), 2)
        let (a, b) = (Self.stops[i], Self.stops[i + 1])
        let t = p - a.0
        let mix = { (x: CGFloat, y: CGFloat) in x + (y - x) * t }
        content
            .rotationEffect(.degrees(a.1 + (b.1 - a.1) * Double(t)))
            .offset(x: mix(a.2, b.2), y: mix(a.3, b.3))
            .opacity(a.4 + (b.4 - a.4) * Double(t))
    }
}
