import BrowserKit
import SwiftUI

/// The tab grid, with the page over it. Opening the grid shrinks the page
/// into its card; one number, `gridProgress`, drives every part of that, so
/// a spring or a finger can move it and stop it anywhere.
///
/// WebKit moves a page's scroll position when it sees its view scaled, so
/// the live page never is: it shows only at rest, and its picture (taken the
/// moment anything starts to move) does the moving, pixel for pixel the same.
struct RootView: View {
    @Environment(Browser.self) private var browser

    /// Reads nothing that changes frame by frame: what moves reads it in
    /// its own modifier, so only that redraws.
    var body: some View {
        @Bindable var browser = browser
        let editing = browser.editing != nil
        let edit: CGFloat = editing ? 1 : 0
        ZStack {
            Backdrop()

            Stage()
            // Arc's sheet: what's behind steps back into a card above it.
            .mask { RoundedRectangle(cornerRadius: 34 * edit, style: .continuous).ignoresSafeArea() }
            .scaleEffect(1 - 0.08 * edit, anchor: .top)
            .offset(y: 36 * edit)
            .allowsHitTesting(!editing)

            if !editing {
                StatusBarScrim()
                    .modifier(BarReveal(slides: false))
                BottomBar()
                    .modifier(BarReveal(slides: true))
                    .transition(.offset(y: 30).combined(with: .opacity))
            }

            if editing {
                AddressSheet()
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        // The keyboard covers what's under it; nothing moves out of its way.
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $browser.showingSettings) { SettingsView() }
        .overlay(alignment: .top) { Notice() }
    }
}

/// The grid, the live page, and the page's picture that does the moving
/// in its place. This body runs every frame of a move; the grid and page
/// views inside it take no inputs, so they aren't rebuilt for it.
private struct Stage: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let grid = browser.gridProgress
        let edit: CGFloat = browser.editing == nil ? 0 : 1
        let tab = browser.selected
        ZStack {
            TabGrid()
                .modifier(GridReveal(progress: grid))
            PageArea()
                .ignoresSafeArea()
                .modifier(AtRest(grid: grid, edit: edit, live: true))
                .allowsHitTesting(grid == 0 && edit == 0)
            // Laid out on the whole screen, so the zoom's arithmetic, in
            // screen points, is where it draws.
            Group {
                if let tab, tab.internalPage == nil {
                    TabPicture(image: browser.snapshots[tab.id])
                } else {
                    PageArea()
                }
            }
            .modifier(Zoom(progress: grid, card: tab.flatMap { browser.cardFrames[$0.id] }))
            .modifier(AtRest(grid: grid, edit: edit, live: false))
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }
}

/// The grid comes up as the page goes into it.
private struct GridReveal: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(min(1, progress * 1.5))
            .allowsHitTesting(progress >= 1)
    }
}

/// The bar (`slides`) and the frost under the clock go as the grid comes.
private struct BarReveal: ViewModifier {
    @Environment(Browser.self) private var browser
    let slides: Bool

    func body(content: Content) -> some View {
        let p = browser.gridProgress
        if slides {
            content
                .opacity(1 - min(1, p * 2.5))
                .offset(y: p * 40)
                .allowsHitTesting(p == 0)
        } else {
            content.opacity(browser.selected == nil ? 0 : 1 - p)
        }
    }
}

/// The page at `progress` between full screen (0) and its card (1): scaled
/// to the card's width, cut to its height, corners rounding as it goes,
/// drawn only, never moving the layout. With no card, it shrinks towards the
/// middle and fades.
struct Zoom: ViewModifier, Animatable {
    var progress: CGFloat
    let card: CGRect?

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let screen = Screen.bounds
        let p = progress
        let target = card ?? screen.insetBy(dx: screen.width * 0.1, dy: screen.height * 0.1)
        let fit = screen.width > 0 ? target.width / screen.width : 1
        let scale = 1 + (fit - 1) * p
        let height = screen.height + (target.height / fit - screen.height) * p
        let radius = Screen.radius + (TabCard.radius / fit - Screen.radius) * p
        content
            .mask(alignment: .top) {
                RoundedRectangle(cornerRadius: p == 0 ? 0 : radius, style: .continuous).frame(height: height)
            }
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: target.minX * p, y: target.minY * p)
            .opacity(card == nil ? 1 - p : 1)
    }
}

/// The live page (`live`) only when nothing is moving it, its stand-in only
/// while something is: judged on the values on screen, frame by frame.
struct AtRest: ViewModifier, Animatable {
    var grid: CGFloat
    var edit: CGFloat
    let live: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(grid, edit) }
        set { grid = newValue.first; edit = newValue.second }
    }

    func body(content: Content) -> some View {
        let rest = grid <= 0.001 && edit <= 0.001
        // Landed on its card, the card shows itself.
        let landed = grid >= 0.999
        content.opacity(live ? (rest ? 1 : 0) : (rest || landed ? 0 : 1))
    }
}

/// Shown only while `progress` rests away from `1 - showsAt`, judged on
/// the value on screen, frame by frame: the page is hidden once it has
/// landed on its card, and the card while the page is away from it.
struct Settled: ViewModifier, Animatable {
    var progress: CGFloat
    let showsAt: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let landed = progress >= 0.999
        content.opacity(showsAt == 1 ? (landed ? 1 : 0) : (landed ? 0 : 1))
    }
}

enum Screen {
    static var bounds: CGRect {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds ?? .zero
    }

    /// The screen's own corners, so the page leaves and lands as the glass does.
    static var radius: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.value(forKey: "_displayCornerRadius") as? CGFloat ?? 44
    }
}

/// Frost behind the clock, fading into the page, so text scrolling up
/// never runs into it.
private struct StatusBarScrim: View {
    var body: some View {
        GeometryReader { box in
            Rectangle()
                .fill(.regularMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: box.safeAreaInsets.top + 16)
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

/// A word along the top that goes by itself.
private struct Notice: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        ZStack {
            if let notice = browser.notice {
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2.5))
                        browser.notice = nil
                    }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: browser.notice)
    }
}

/// Behind everything: the soft lavender Arc and Safari put behind their tabs.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.12, green: 0.12, blue: 0.17), Color(red: 0.08, green: 0.08, blue: 0.11)]
                : [Color(red: 0.91, green: 0.90, blue: 0.97), Color(red: 0.86, green: 0.86, blue: 0.94), Color(red: 0.92, green: 0.89, blue: 0.93)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

/// The selected tab, and while the address bar is dragged sideways, the
/// tab it's being dragged towards.
struct PageArea: View {
    @Environment(Browser.self) private var browser
    static let gap: CGFloat = 12

    var body: some View {
        let _ = browser.revision
        let (previous, next) = browser.neighbours
        // The live page stays still; pictures do the sliding, the tab's
        // own beside its neighbour's.
        current
            .modifier(Slide(offset: browser.pageOffset, live: true))
            .overlay {
                ZStack {
                    TabPicture(image: browser.selected.flatMap { browser.snapshots[$0.id] })
                    TabPicture(image: previous.flatMap { browser.snapshots[$0.id] })
                        .offset(x: -Screen.bounds.width - Self.gap)
                    TabPicture(image: next.flatMap { browser.snapshots[$0.id] })
                        .offset(x: Screen.bounds.width + Self.gap)
                }
                .modifier(Slide(offset: browser.pageOffset, live: false))
                .allowsHitTesting(false)
            }
    }

    @ViewBuilder private var current: some View {
        if let tab = browser.selected {
            if let page = tab.internalPage {
                InternalPageView(page: page)
            } else {
                WebHost(tab: tab, webView: tab.webView)
            }
        } else {
            NewTabPage()
        }
    }
}

/// The live page while nothing slides it; the pictures, moved along by
/// `offset`, while something does. Judged frame by frame.
struct Slide: ViewModifier, Animatable {
    var offset: CGFloat
    let live: Bool

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func body(content: Content) -> some View {
        let still = abs(offset) < 0.5
        if live {
            content.opacity(still ? 1 : 0)
        } else {
            content.offset(x: offset).opacity(still ? 0 : 1)
        }
    }
}

/// A tab as a picture: its last snapshot, top aligned, or a plain page.
struct TabPicture: View {
    let image: UIImage?

    var body: some View {
        Color(.systemBackground)
            .overlay(alignment: .top) {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
    }
}

/// What shows with no tab: Browser's picture, your own, a colour, or plain.
struct NewTabPage: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        let _ = prefs.newTabImageVersion
        Group {
            switch prefs.settings.newTabPage {
            case .image:
                if let url = Settings.newTabImageInUse, let image = UIImage(contentsOfFile: url.path) {
                    // Fills whatever space it's given, never widening it.
                    Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }.clipped()
                } else {
                    Color(.systemBackground)
                }
            case .color:
                Color(hex: prefs.settings.newTabColor)
            case .blank:
                Color(.systemBackground)
            }
        }
        .ignoresSafeArea()
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }

    var hex: String {
        let c = UIColor(self).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0]
        return String(format: "#%02X%02X%02X", Int(c[0] * 255), Int(c[1] * 255), Int(c[2] * 255))
    }

    /// Persist's blue, the Mac sidebar's.
    static let persist = Color(red: 0.36, green: 0.60, blue: 1)
}
