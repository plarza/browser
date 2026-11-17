import BrowserKit
import SwiftUI

/// Browser's own pages, as native views in the tab: about://settings,
/// about://history, about://downloads, about://userscripts and about://help.
@MainActor
enum InternalPages {
    static func view(_ page: InternalPage, browser: Browser) -> AnyView {
        switch page {
        case .history: AnyView(HistoryPage { url in browser.selected?.load(url) })
        case .downloads: AnyView(DownloadsPage())
        case .settings: AnyView(SettingsPage())
        case .userscripts: AnyView(UserscriptsPage())
        case .help: AnyView(HelpPage())
        }
    }

    /// Side margins that keep a page's content 720 points wide at most,
    /// with its scroll bar still at the window's edge.
    static func margin(_ width: CGFloat) -> CGFloat { max(24, (width - 720) / 2) }
}

extension View {
    /// A scrolling page's content, 720 points wide at most.
    func readableWidth() -> some View {
        GeometryReader { geometry in
            contentMargins(.horizontal, InternalPages.margin(geometry.size.width), for: .scrollContent)
        }
    }
}
