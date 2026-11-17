import AppKit
import BrowserKit
import SwiftUI

/// Everything right of the sidebar: the selected tab's page on the stage,
/// or one of Browser's own pages in its place, or nothing at all over the
/// new tab page; and over them the install bar, the sidebar's shadow, the
/// progress line and the find bar.
@MainActor
final class PageArea: Surface {
    /// The selected tab's page, and nothing but it.
    let stage = Stage()
    /// Browser's own pages, native, where the web view would be.
    let pageHost = NSHostingView(rootView: AnyView(EmptyView()))
    /// Over a .user.js file: Install.
    let installBar = InstallBar()
    let progressLine: ProgressLine
    let findBar: FindBar
    /// Which of Browser's own pages is showing, if one is.
    private(set) var shownPage: InternalPage?

    private let browser: Browser
    private let sidebarShadow = SidebarShadow()
    private var following: Observer?

    init(browser: Browser) {
        self.browser = browser
        progressLine = ProgressLine(browser: browser)
        findBar = FindBar(browser: browser)
        super.init(frame: .zero)
        addPinned(stage)
        addPinned(pageHost)
        // The page takes the page area's size. Left to itself the hosting
        // view sizes the window to its page: a short one would shrink it.
        pageHost.sizingOptions = []
        pageHost.isHidden = true
        // Over the page, under the progress line.
        installBar.isHidden = true
        for view in [installBar, sidebarShadow, progressLine, findBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        findBar.isHidden = true
        NSLayoutConstraint.activate([
            installBar.topAnchor.constraint(equalTo: topAnchor),
            installBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            installBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            installBar.heightAnchor.constraint(equalToConstant: InstallBar.height),

            sidebarShadow.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebarShadow.topAnchor.constraint(equalTo: topAnchor),
            sidebarShadow.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarShadow.widthAnchor.constraint(equalToConstant: 40),

            progressLine.topAnchor.constraint(equalTo: topAnchor),
            progressLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressLine.heightAnchor.constraint(equalToConstant: 2),

            findBar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        following = Observer { [weak self] in
            let tab = browser.selected
            self?.show(blank: tab?.isBlank ?? false, page: tab?.page)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A blank tab shows the new tab page through a clear page area; one of
    /// Browser's own pages hides the stage, page and all.
    private func show(blank: Bool, page: InternalPage?) {
        stage.isHidden = blank || page != nil
        isClear = blank
        pageHost.isHidden = page == nil
        guard page != shownPage else { return }
        shownPage = page
        pageHost.rootView = page.map { InternalPages.view($0, browser: browser) } ?? AnyView(EmptyView())
    }
}

/// Where pages show, and the only place they do: one tab's page at a time.
/// Showing a tab takes everything else off it, so no other tab's page, and
/// no picture of one, can be seen in its place. A blank tab or one of
/// Browser's own pages hides it, page and all.
@MainActor
final class Stage: NSView {
    private(set) var page: PageView?

    func show(_ page: PageView) {
        self.page = page
        for view in subviews where view !== page { view.removeFromSuperview() }
        guard page.superview !== self else { return }
        // Web Inspector resizes the inspected view when docked. Edge
        // constraints would force it back over the inspector on every layout.
        page.translatesAutoresizingMaskIntoConstraints = true
        page.autoresizingMask = [.width, .height]
        page.frame = bounds
        addSubview(page)
    }

    /// A picture of the page's own back or forward page, beside it during a
    /// swipe; it goes with the page the moment another tab shows.
    func add(_ picture: NSView, below: Bool) {
        guard let page else { return }
        addSubview(picture, positioned: below ? .below : .above, relativeTo: page)
    }
}

/// The sidebar's shadow along the page's left edge, so the sidebar reads
/// as lying on top of the page: wide and faint. Clicks go through it.
@MainActor
final class SidebarShadow: NSView {
    private let gradient = CAGradientLayer()
    private static let width: CGFloat = 18

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [0.035, 0.014, 0].map { NSColor.black.withAlphaComponent($0).cgColor }
        gradient.locations = [0, 0.35, 1]
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.run { gradient.frame = NSRect(x: 0, y: 0, width: SidebarShadow.width, height: bounds.height) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
