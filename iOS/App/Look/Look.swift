import BrowserKit
import SwiftUI
import UIKit

/// BrowserKit's, not SwiftUI's.
typealias Tab = BrowserKit.Tab
typealias Settings = BrowserKit.Settings

/// The measures and colours the screens share.
enum Look {
    /// Persist's blue, the Mac's: a ring on the address bar and the card.
    static let persist = UIColor(red: 0x5C / 255, green: 0x99 / 255, blue: 1, alpha: 1)
    /// A card's corners in the grid.
    static let cardRadius: CGFloat = 22
    /// What stepped back behind the address sheet: its corners.
    static let steppedRadius: CGFloat = 34
    /// How much of the page the bar covers, above the home indicator.
    static let barHeight: CGFloat = 58
    /// Between the page and the next tab's, swiping between them.
    static let gap: CGFloat = 12
    static let placeholder = "Search or enter website name"

    /// The screen's own corners, so a page leaves and lands as the glass does.
    @MainActor
    static func screenRadius(of view: UIView) -> CGFloat {
        view.window?.screen.value(forKey: "_displayCornerRadius") as? CGFloat ?? 44
    }

    /// An address as a list shows it under a page's title: without its
    /// scheme and `www.`, and without the slash that ends a bare site.
    static func address(_ url: String) -> String {
        let bare = History.bare(url)
        return bare.hasSuffix("/") && !bare.dropLast().contains("/") ? String(bare.dropLast()) : bare
    }

    /// A site's name as the address bar shows it: without `www.`.
    static func site(_ host: String?) -> String {
        guard let host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension Tab {
    /// What the address bar calls the tab: the site's name, or one of
    /// Browser's own pages by name. Nil for a tab with nowhere to go.
    var site: String? {
        // A tab not yet woken knows only its address.
        if let page = page ?? InternalPage(url) { return page.title }
        guard let host = url?.host else { return url?.isFileURL == true ? url?.lastPathComponent : nil }
        return Look.site(host)
    }

    /// What a card calls the tab.
    var cardTitle: String {
        if page == nil, InternalPage(url) == nil, !title.isEmpty { return title }
        return site ?? "New Tab"
    }

    /// The site's icon; for Browser's own pages, the logo in grey.
    var icon: UIImage? {
        page ?? InternalPage(url) == nil ? Favicons.shared.icon(for: url) : Favicons.browser
    }
}

extension Browser {
    /// The tabs either side of the one showing.
    var neighbours: (previous: Tab?, next: Tab?) {
        guard let index = index(of: selected) else { return (nil, nil) }
        return (index > 0 ? tabs[index - 1] : nil, index + 1 < tabs.count ? tabs[index + 1] : nil)
    }
}

extension Color {
    static let persist = Color(uiColor: Look.persist)

    /// `#RRGGBB`, as Settings keeps the new tab page's colour.
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: nil)
        let byte = { (part: CGFloat) in Int((min(max(part, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
