import BrowserKit
import SwiftUI

/// The live pages, the tab grid over them, and over that the page's picture
/// in flight (see `Stage`), with the bar and the address sheet on top.
/// Opening the grid shrinks the page into its card; one number,
/// `gridProgress`, drives every part of that, so a spring or a finger can
/// move it and stop it anywhere.
struct RootView: View {
    @Environment(Browser.self) private var browser

    /// Reads nothing that changes frame by frame: what moves reads it in
    /// its own view, so only that redraws.
    var body: some View {
        @Bindable var browser = browser
        let editing = browser.editing != nil
        ZStack {
            Backdrop()
            LivePages()
            GridLayer()
            Flight()
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

private struct LivePages: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        PagesLayer(revision: browser.revision, selected: browser.selected, offset: browser.pageOffset)
            .ignoresSafeArea()
    }
}

private struct Flight: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        FlyerLayer(grid: browser.gridProgress, edit: browser.editing == nil ? 0 : 1)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// The grid comes up as the page goes into it, and steps back, as the page
/// does, behind the address sheet.
private struct GridLayer: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let p = browser.gridProgress
        let edit: CGFloat = browser.editing == nil ? 0 : 1
        TabGrid()
            .mask { RoundedRectangle(cornerRadius: 34 * edit, style: .continuous).ignoresSafeArea() }
            .scaleEffect(1 - 0.08 * edit, anchor: .top)
            .offset(y: 36 * edit)
            .opacity(min(1, p * 1.5))
            .allowsHitTesting(p >= 1 && edit == 0)
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
