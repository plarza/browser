import AppKit
import BrowserKit

/// Browser's tab, not SwiftUI's.
typealias Tab = BrowserKit.Tab

/// The one window, and the shell BrowserKit talks to: the sidebar down the
/// left, the page area filling the rest, the new tab page behind both. It
/// owns the `Browser` and arranges the parts; each part follows the browser
/// by itself.
@MainActor
final class BrowserWindowController: NSWindowController {
    let browser = Browser()
    let sidebar: Sidebar
    let pageArea: PageArea
    /// Behind a blank tab, and behind the whole window with Fill.
    let newTabPage = NewTabPage()
    let commands: Commands
    let swipes: SwipeNavigation
    /// The install bar's offer of the script the tab shows.
    let installOffer: InstallOffer

    /// An extension's popup, while it is up.
    var popover: NSPopover?
    /// The window's local event monitors, kept for as long as it is.
    var monitors: [EventMonitor] = []
    private var following: [Observer] = []
    /// The tab whose page the stage shows.
    private weak var shown: Tab?
    /// The new tab page behind the page area alone, or under the whole window.
    private var behind: (page: NSLayoutConstraint, window: NSLayoutConstraint)?
    private(set) var fills = false

    init() {
        let window = BrowserWindow()
        sidebar = Sidebar(browser: browser)
        pageArea = PageArea(browser: browser)
        commands = Commands()
        swipes = SwipeNavigation(browser: browser, pageArea: pageArea)
        installOffer = InstallOffer(browser: browser, bar: pageArea.installBar)
        super.init(window: window)
        Dialogs.window = window
        browser.shell = self
        commands.shell = self
        arrange()
        connect()
        watchEvents()
        follow()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Arranging

    /// White, flush, nothing floating: the sidebar (traffic lights, the
    /// field, the tabs) and the page filling everything else, with the new
    /// tab page behind everything.
    private func arrange() {
        guard let root = window?.contentView else { return }
        pageArea.translatesAutoresizingMaskIntoConstraints = false
        newTabPage.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(newTabPage)
        root.addSubview(pageArea)
        sidebar.place(in: root)
        let behind = (
            page: newTabPage.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            window: newTabPage.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        )
        self.behind = behind
        NSLayoutConstraint.activate([
            pageArea.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            pageArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageArea.topAnchor.constraint(equalTo: root.topAnchor),
            pageArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            behind.page,
            newTabPage.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            newTabPage.topAnchor.constraint(equalTo: pageArea.topAnchor),
            newTabPage.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor),
        ])
        // The extensions' row shares the traffic lights' centre line.
        if let close = window?.standardWindowButton(.closeButton) {
            sidebar.actionBar.centerYAnchor.constraint(equalTo: close.centerYAnchor).isActive = true
        }
    }

    /// What the parts ask of each other.
    private func connect() {
        sidebar.addressField.onSubmit = { [weak self] text in self?.go(text) }
        sidebar.addressField.onEscape = { [weak self] in self?.focusPage() }
        sidebar.onResize = { [weak self] in self?.placeGlass(animated: $0) }
        sidebar.downloadRows.onShowAll = { [weak self] in self?.show(.downloads) }
        sidebar.actionBar.scriptsMenu.onOpenUserscripts = { [weak self] in self?.show(.userscripts) }
        pageArea.findBar.onClose = { [weak self] in
            self?.hideFind()
            self?.focusPage()
        }
        installOffer.onOpenUserscripts = { [weak self] in self?.show(.userscripts) }
    }

    // MARK: Following the browser

    private func follow() {
        following = [
            Observer { [weak self] in
                guard let self else { return }
                let tab = browser.selected
                if tab !== shown { show(tab) }
            },
            Observer { [weak self] in
                guard let self, let tab = browser.selected else { return }
                window?.title = tab.title.isEmpty ? "Browser" : tab.title
            },
            Observer { [weak self] in
                guard let self else { return }
                let settings = Preferences.shared.settings
                let blank = browser.selected?.isBlank ?? false
                fill(settings.fill)
                newTabPage.isHidden = !blank && !fills
                // The desktop shows through a blank tab, or through every
                // tab's sidebar with Fill.
                (window as? BrowserWindow)?.isClear = settings.newTabPage == .blank && (blank || fills)
            },
        ]
    }

    /// Another tab is selected: its page takes the stage, and the keyboard
    /// goes to the field if the tab has nowhere to go, else to the page.
    private func show(_ tab: Tab?) {
        let previous = shown
        shown = tab
        swipes.end(unlessIn: tab)
        if let tab { pageArea.stage.show(tab.view) }
        pageArea.findBar.dismiss()
        previous?.hideFind()
        tab?.hideFind()
        guard let tab else { return }
        if tab.url == nil, tab.pending == nil { focusAddress() } else { focusPage() }
    }

    /// The new tab page's picture under the whole window, seen through a
    /// frosted sidebar.
    private func fill(_ on: Bool) {
        guard on != fills, let behind else { return }
        fills = on
        behind.page.isActive = !on
        behind.window.isActive = on
        sidebar.isClear = on
        placeGlass(animated: false)
    }

    /// The glass lies under the sidebar, as wide as it is, and goes when it does.
    private func placeGlass(animated: Bool) {
        newTabPage.setGlassWidth(fills && sidebar.isShown ? sidebar.width : 0, animated: animated)
    }

    // MARK: Going places

    /// What was typed into the address field, or pasted for Paste and Go.
    func go(_ text: String) {
        switch browser.go(text) {
        case .go: focusPage()
        case .needsSearchEngine: sidebar.addressField.flash("No search engine set (⌘,)")
        case nil: break
        }
    }

    /// A link or file from another app: into the blank tab if that's what's showing.
    func open(_ url: URL) {
        browser.open(url)
        focusPage()
    }

    /// One of Browser's own pages.
    func show(_ page: InternalPage) {
        browser.show(page)
        focusPage()
    }

    // MARK: Keyboard focus

    func focusPage() {
        guard let tab = browser.selected else { return }
        window?.makeFirstResponder(tab.webView)
    }

    /// ⌘L, or a tab with nowhere to go: the field, with everything in it selected.
    func focusAddress() {
        if !sidebar.isShown { sidebar.toggle() }
        sidebar.addressField.focus()
    }

    func hideFind() {
        pageArea.findBar.dismiss()
        browser.selected?.hideFind()
    }
}
