import Foundation
import Observation
import WebKit

/// The tabs and which one is showing: what the Mac's window and the
/// iPhone's screen both arrange. Every rule about opening, closing and
/// restoring tabs lives here, so each shell only draws.
@MainActor @Observable
public final class Browser {
    public private(set) var tabs: [Tab] = []
    public private(set) var selected: Tab?
    @ObservationIgnored public weak var shell: Shell?

    /// Addresses of the tabs closed this session, for Reopen Closed Tab.
    private var closed: [URL] = []
    @ObservationIgnored private var saver: Observer?

    #if os(macOS)
    /// The Mac's window always has a tab, blank if need be, and a link's
    /// new tab opens behind the page.
    private static let keepsATab = true, selectsLinkedTabs = false
    #else
    /// The iPhone has no blank tabs (New Tab opens none until you go
    /// somewhere), and a link's new tab comes to the front.
    private static let keepsATab = false, selectsLinkedTabs = true
    #endif

    public init() {
        Extensions.shared.browser = self
    }

    // MARK: Launch

    /// The last session's tabs, asleep until shown: a Persist tab in its
    /// jar, every other tab in a fresh identity.
    public func restore() {
        let session = Session.restore()
        for saved in session.tabs {
            let tab = Tab(browser: self)
            tab.restore(saved.url, kept: saved.jar)
            tabs.append(tab)
            Extensions.shared.didOpen(tab)
        }
        // Jars nothing refers to are deleted, but only when what refers to
        // them could be read: launched while the device is locked, Browser
        // can't read its own files, and every jar would look like an orphan.
        if Store.isReadable("settings.json"), Store.isReadable("tabs.json") {
            Task { await Identity.removeOrphans(keeping: Set(session.tabs.compactMap(\.jar))) }
        }
        if !tabs.isEmpty {
            select(tabs[min(max(session.selected, 0), tabs.count - 1)])
        } else if Browser.keepsATab {
            newTab()
        }
        // From here on the open tabs are saved whenever they change.
        saver = Observer { [weak self] in self?.save() }
    }

    /// Saves the open tabs now. They are saved a moment after each change
    /// anyway; a shell about to quit or leave the foreground calls this so
    /// the last change isn't lost.
    public func save() {
        Session.save(tabs, selected: selected)
    }

    // MARK: Tabs

    /// A new tab in a fresh identity, placed where Settings says, loading
    /// `url` if there is one.
    @discardableResult
    public func newTab(_ url: URL? = nil, as kind: History.Kind = .link, after anchor: Tab? = nil, select shouldSelect: Bool = true) -> Tab {
        let tab = Tab(browser: self)
        let anchor = anchor ?? selected
        switch Preferences.shared.settings.newTabPosition {
        case .top:
            tabs.insert(tab, at: 0)
        case .below where anchor != nil:
            tabs.insert(tab, at: (index(of: anchor) ?? tabs.count - 1) + 1)
        case .below, .bottom:
            tabs.append(tab)
        }
        Extensions.shared.didOpen(tab)
        if let url { tab.load(url, as: kind) }
        if shouldSelect { select(tab) }
        return tab
    }

    /// A link from another app: into the blank tab if that's what's showing.
    public func open(_ url: URL) {
        if let tab = selected, tab.isBlank { tab.load(url) } else { newTab(url) }
    }

    public func select(_ tab: Tab) {
        guard index(of: tab) != nil else { return }
        let previous = selected
        selected = tab
        tab.wake()
        if previous !== tab { Extensions.shared.didActivate(tab, previous: previous) }
    }

    /// Closes `tab` and destroys its session, without asking.
    public func close(_ tab: Tab) {
        guard let index = index(of: tab) else { return }
        if let url = tab.url, !tab.isPopup { closed.append(url) }
        for popup in tab.popups { close(popup) }
        tab.close()
        tabs.removeAll { $0 === tab }
        Extensions.shared.didClose(tab)
        guard selected === tab else { return }
        selected = nil
        if let opener = tab.opener, self.index(of: opener) != nil {
            select(opener)
        } else if !tabs.isEmpty {
            select(tabs[min(index, tabs.count - 1)])
        } else if Browser.keepsATab {
            newTab()
        }
    }

    /// A person closing a tab (⌘W, its ✕, its menu, a swipe): a Persist tab
    /// asks first. Pages and extensions closing tabs don't.
    @discardableResult
    public func closeAsking(_ tab: Tab) async -> Bool {
        if tab.persist, !tab.isPopup, let shell, !(await shell.confirmClosing(tab)) { return false }
        close(tab)
        return true
    }

    /// Moves the tab at `from` to sit before the one now at `to`.
    public func move(from: Int, to: Int) {
        guard tabs.indices.contains(from) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(0, to > from ? to - 1 : to), tabs.count))
        Extensions.shared.didMove(tab, from: from)
    }

    public var canReopenClosedTab: Bool { !closed.isEmpty }

    public func reopenClosedTab() {
        if let url = closed.popLast() { newTab(url) }
    }

    public func duplicate(_ tab: Tab) {
        if let url = tab.url { newTab(url, after: tab) }
    }

    /// The tab `offset` places after the selected one, around the ends.
    public func selectTab(offset: Int) {
        guard let index = index(of: selected) else { return }
        select(tabs[((index + offset) % tabs.count + tabs.count) % tabs.count])
    }

    /// ⌘1 to ⌘8 pick a tab by its place; ⌘9 is always the last.
    public func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        select(number == 9 ? tabs[tabs.count - 1] : tabs[min(max(number, 1), tabs.count) - 1])
    }

    public func index(of tab: Tab?) -> Int? {
        tabs.firstIndex { $0 === tab }
    }

    // MARK: Going places

    /// What was typed (or pasted) into the address field: an address, a
    /// bang, one of Browser's own pages, or words for the search engine.
    /// `inNewTab`: for a tab that doesn't exist until there is somewhere to go.
    @discardableResult
    public func go(_ text: String, inNewTab: Bool = false) -> Address.Result? {
        let result = Address.resolve(text, searchTemplate: Preferences.shared.settings.searchTemplate)
        guard case .go(let url) = result else { return result }
        if let page = InternalPage(url) {
            show(page)
        } else {
            // An address counts as typed in History; a search or a bang doesn't.
            let kind: History.Kind = Address.isAddress(text) ? .typed : .link
            if let tab = selected, !inNewTab { tab.load(url, as: kind) } else { newTab(url, as: kind) }
        }
        return result
    }

    /// One of Browser's own pages: the tab already showing it, else this
    /// one if it's blank, else a new tab.
    public func show(_ page: InternalPage) {
        if let open = tabs.first(where: { $0.url == page.url }) {
            select(open)
        } else if let tab = selected, tab.isBlank {
            tab.load(page.url)
        } else {
            newTab(page.url)
        }
    }

    // MARK: What tabs ask for

    /// ⌘-click, middle-click, target=_blank: a new tab with a new identity.
    func open(_ url: URL, from tab: Tab) {
        newTab(url, after: tab, select: Browser.selectsLinkedTabs)
    }

    /// A `window.open` popup sharing its opener's jar: beside it, in front.
    func adopt(_ popup: Tab, from opener: Tab) {
        tabs.insert(popup, at: (index(of: opener) ?? tabs.count - 1) + 1)
        Extensions.shared.didOpen(popup)
        select(popup)
    }

    /// A userscript granted `window.focus` asked for its tab.
    func focus(_ tab: Tab) {
        select(tab)
        shell?.bringForward(tab)
    }
}
