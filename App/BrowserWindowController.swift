import AppKit
import Combine
import SwiftUI
import CoreKit
import UniformTypeIdentifiers
import WebKit

/// Core's tab, not SwiftUI's.
typealias Tab = CoreKit.Tab

/// The one window: tabs down the left, the page on the right, one field
/// above the tabs.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private(set) var tabs: [Tab] = []
    private(set) var selected: Tab?
    private var closed: [URL] = []

    private let sidebar = Sidebar()
    fileprivate let address = AddressField()
    private let tabList = TabListView()
    private let actionBar = ActionBar()
    fileprivate let content = PageArea()
    private let progress = ProgressLine()
    private let findBar = FindBar()
    private let divider = SidebarDivider()
    private var sidebarWidth: NSLayoutConstraint!
    private var sidebarLeading: NSLayoutConstraint!
    private var popover: NSPopover?
    /// Behind a blank tab: the new tab page.
    private let backdrop = NewTabBackdrop()
    private let downloads = DownloadDock()
    fileprivate let shade = SidebarShadow()
    /// Core's own pages, native, where the web view would be.
    private let pageHost = NSHostingView(rootView: AnyView(EmptyView()))
    private var hostedPage: String?
    private var watching: Set<AnyCancellable> = []
    private static let widths: ClosedRange<CGFloat> = 200 ... 420
    private var width: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "sidebarWidth"))
        return saved > 0 ? min(max(saved, widths.lowerBound), widths.upperBound) : 248
    }()

    init() {
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        // Clear, so a blank tab's frosted page can show the desktop through
        // it; the sidebar and the page paint their own white.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("Core")
        if window.frame.origin == .zero { window.center() }
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        layout()
        alignActionBar()
        watchNewTabPage()
        watchClicks()
        watchSwipes()
        watchMouseButtons()
        watchHelpKey()
        watchDownloads()
    }

    private func watchNewTabPage() {
        // Behind everything: under the page area, or under the whole
        // window (the sidebar too) when it fills.
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        if let root = window?.contentView { root.addSubview(backdrop, positioned: .below, relativeTo: nil) }
        backdropLeading = (
            page: backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            window: backdrop.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor)
        )
        NSLayoutConstraint.activate([
            backdropLeading.page,
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        pageHost.isHidden = true
        content.addSubview(pageHost, positioned: .below, relativeTo: progress)
        NSLayoutConstraint.activate([
            pageHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageHost.topAnchor.constraint(equalTo: content.topAnchor),
            pageHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        shade.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(shade, positioned: .below, relativeTo: progress)
        NSLayoutConstraint.activate([
            shade.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            shade.topAnchor.constraint(equalTo: content.topAnchor),
            shade.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            shade.widthAnchor.constraint(equalToConstant: 40),
        ])
        let prefs = Preferences.shared
        prefs.$settings.combineLatest(prefs.$newTabImageVersion)
            .receive(on: RunLoop.main)
            .sink { [weak self] settings, version in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.backdrop.update(settings, imageVersion: version)
                    self.fill(settings.fill)
                }
            }
            .store(in: &watching)
    }

    private var backdropLeading: (page: NSLayoutConstraint, window: NSLayoutConstraint)!
    private var fills = false

    /// The new tab page's picture under the whole window, seen through a
    /// frosted sidebar.
    private func fill(_ on: Bool) {
        guard on != fills else { return }
        fills = on
        backdropLeading.page.isActive = !on
        backdropLeading.window.isActive = on
        sidebar.isFrosted = on
        backdrop.glassWidth = on ? width : 0
        updateNewTabPage()
    }

    /// The new tab page shows while the tab has nothing in it.
    private func updateNewTabPage() {
        let blank = selected.map { $0.url == nil && $0.pending == nil && !$0.isLoading } ?? false
        let page = selected?.internalPage
        selected?.webView.isHidden = blank || page != nil
        content.isClear = blank
        backdrop.isHidden = !blank && !fills
        backdrop.alphaValue = 1
        pageHost.isHidden = page == nil
        if let page, page != hostedPage {
            pageHost.rootView = Pages.view(page) { [weak self] url in self?.selected?.load(url) }
        }
        hostedPage = page
    }

    /// A mouse's back and forward buttons do what ⌘[ and ⌘] do. WebKit
    /// would otherwise take them for its own lists, which a wipe empties.
    private var buttonMonitor: Any?

    /// ⇧⌘/ is macOS's own "search the Help menu"; in Core it opens
    /// about://help, before the system can take it.
    private var helpMonitor: Any?

    private func watchHelpKey() {
        helpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { () -> NSEvent? in
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
                guard let self, event.window === self.window, mods == [.command, .shift],
                      event.charactersIgnoringModifiers == "/" || event.charactersIgnoringModifiers == "?" || event.keyCode == 44
                else { return event }
                self.showHelp(nil)
                return nil
            }
        }
    }

    private func watchDownloads() {
        downloads.onShowAll = { [weak self] in self?.showDownloads(nil) }
    }

    private func watchMouseButtons() {
        buttonMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { () -> NSEvent? in
                guard let self, event.window === self.window, event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
                if event.type == .otherMouseDown { self.mouseButton(event.buttonNumber) }
                return nil
            }
        }
    }

    fileprivate func mouseButton(_ number: Int) {
        if number == 3 { selected?.goBack() } else { selected?.goForward() }
    }

    /// Two-finger swipes left and right go back and forward, as in Safari.
    /// Core keeps its own back and forward lists (a wipe swaps the web view
    /// out), so the swipe is followed here, from the scroll gesture's phases:
    /// a chevron follows the fingers in from the edge, and letting go past
    /// it navigates.
    private var swipeMonitor: Any?
    private let swipeArrow = NSImageView()
    private var swipe: (back: Bool, distance: CGFloat)?
    private static let swipeDistance: CGFloat = 160

    private func watchSwipes() {
        swipeArrow.symbolConfiguration = .init(pointSize: 30, weight: .regular).applying(.init(hierarchicalColor: .secondaryLabelColor))
        swipeArrow.alphaValue = 0
        content.addSubview(swipeArrow)
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                      self.content.bounds.contains(self.content.convert(event.locationInWindow, from: nil))
                else { return }
                self.follow(event.phase, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
            }
            return event
        }
    }

    fileprivate func follow(_ phase: NSEvent.Phase, dx: CGFloat, dy: CGFloat) {
        guard let tab = selected else { return }
        switch phase {
        case .began:
            guard abs(dx) > abs(dy) * 2 else { return }
            // Fingers moving right (a positive delta) mean back.
            let back = dx > 0
            guard back ? tab.canGoBack : tab.canGoForward else { return }
            swipe = (back, abs(dx))
            swipeArrow.image = NSImage(systemSymbolName: back ? "chevron.backward.circle.fill" : "chevron.forward.circle.fill", accessibilityDescription: nil)
            showSwipe()
        case .changed:
            guard let current = swipe else { return }
            swipe?.distance = max(0, current.distance + (current.back ? dx : -dx))
            showSwipe()
        case .ended, .cancelled:
            guard let current = swipe else { return }
            swipe = nil
            if phase == .ended, current.distance >= Self.swipeDistance {
                if current.back { tab.goBack() } else { tab.goForward() }
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                swipeArrow.animator().alphaValue = 0
            }
        default:
            break
        }
    }

    private func showSwipe() {
        guard let swipe else { return }
        let size: CGFloat = 44
        let progress = min(swipe.distance / Self.swipeDistance, 1)
        let rest = swipe.back ? -size : content.bounds.width
        let travel = (size + 20) * progress
        swipeArrow.frame = NSRect(x: swipe.back ? rest + travel : rest - travel, y: content.bounds.midY - size / 2, width: size, height: size)
        swipeArrow.alphaValue = progress
    }

    /// A click anywhere but the field, while editing it, leaves it: on the
    /// page, focus goes to the page; elsewhere, to nothing.
    private var clickMonitor: Any?

    private func watchClicks() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { () -> NSEvent? in
                guard let self, let window = self.window, event.window === window else { return event }
                let inside = self.address.bounds.contains(self.address.convert(event.locationInWindow, from: nil))
                // The first click on the field focuses it with everything
                // selected, as Safari's does; later clicks place the caret.
                if inside, !self.address.isEditing, event.type == .leftMouseDown {
                    self.address.focus()
                    return nil
                }
                // Any other field being typed in (Settings' add rows, the
                // find bar) lets go when the click lands outside it.
                if !self.address.isEditing, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                   let field = editor.delegate as? NSView,
                   !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                    window.makeFirstResponder(nil)
                    return event
                }
                let list = self.address.suggestions
                let onList = list.isShown && list.bounds.contains(list.convert(event.locationInWindow, from: nil))
                guard self.address.isEditing, !inside, !onList else { return event }
                if let web = self.selected?.webView, web.superview != nil,
                   web.bounds.contains(web.convert(event.locationInWindow, from: nil)) {
                    window.makeFirstResponder(web)
                } else {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// White, flush, nothing floating: the sidebar (traffic lights, the
    /// field, the tabs) and the page filling everything else. The edge
    /// between them drags.
    private func layout() {
        guard let root = window?.contentView else { return }

        address.onSubmit = { [weak self] text in self?.go(text) }
        address.onEscape = { [weak self] in self?.focusPage() }

        tabList.onSelect = { [weak self] tab in self?.select(tab) }
        tabList.onClose = { [weak self] tab in self?.close(tab) }
        tabList.onPersist = { tab in tab.persist.toggle() }
        tabList.onMove = { [weak self] from, to in self?.move(from: from, to: to) }
        tabList.onDuplicate = { [weak self] tab in if let url = tab.url { self?.newTab(url, after: tab) } }

        divider.onDrag = { [weak self] delta in self?.resizeSidebar(by: delta) }
        divider.onEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.width), forKey: "sidebarWidth")
        }

        actionBar.onClick = { [weak self] action, button in self?.perform(action, from: button) }

        for view in [sidebar, content, divider, address, actionBar, tabList, progress, findBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(content)
        root.addSubview(sidebar)
        root.addSubview(divider)
        downloads.translatesAutoresizingMaskIntoConstraints = false
        for view in [address, actionBar, tabList, downloads] as [NSView] { sidebar.addSubview(view) }
        // Over the tabs, under the field.
        address.suggestions.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(address.suggestions)
        content.addSubview(progress)
        content.addSubview(findBar)
        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFind() }
        findBar.onSearch = { [weak self] text, back in self?.find(text, backwards: back) }

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: width)
        sidebarLeading = sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        NSLayoutConstraint.activate([
            sidebarLeading,
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,

            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            divider.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 8),

            // Below the traffic lights.
            address.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 42),
            address.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            address.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            address.suggestions.topAnchor.constraint(equalTo: address.bottomAnchor, constant: 6),
            address.suggestions.leadingAnchor.constraint(equalTo: address.leadingAnchor, constant: -2),
            address.suggestions.trailingAnchor.constraint(equalTo: address.trailingAnchor, constant: 2),

            // In the traffic lights' row, after them.
            actionBar.heightAnchor.constraint(equalToConstant: 22),
            actionBar.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 78),
            actionBar.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),

            tabList.topAnchor.constraint(equalTo: address.bottomAnchor, constant: 10),
            tabList.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            tabList.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            tabList.bottomAnchor.constraint(equalTo: downloads.topAnchor, constant: -6),
            downloads.leadingAnchor.constraint(equalTo: tabList.leadingAnchor),
            downloads.trailingAnchor.constraint(equalTo: tabList.trailingAnchor),
            downloads.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),

            progress.topAnchor.constraint(equalTo: content.topAnchor),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),

            findBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
        ])
    }

    /// The extensions' row shares the traffic lights' centre line.
    private func alignActionBar() {
        guard let close = window?.standardWindowButton(.closeButton) else { return }
        actionBar.centerYAnchor.constraint(equalTo: close.centerYAnchor).isActive = true
    }

    private func resizeSidebar(by delta: CGFloat) {
        width = min(max(width + delta, Self.widths.lowerBound), Self.widths.upperBound)
        sidebarWidth.constant = width
        if fills { backdrop.glassWidth = width }
    }

    // MARK: Tabs

    func restore() {
        let saved = OpenTabs.restore()
        for saved in saved.tabs { newTab(nil, select: false, focus: false, restoring: true).restore(saved.url, kept: saved.kept) }
        let kept = Set(saved.tabs.compactMap { $0.kept?.id })
        Task { await Identity.removeOrphans(keeping: kept) }
        if tabs.isEmpty {
            newTab(nil)
        } else {
            select(tabs[min(max(saved.selected, 0), tabs.count - 1)])
        }
        saveTabs()
    }

    private var savedSignature = ""

    func saveTabs() {
        let own = tabs.filter { $0.opener == nil && $0.url != nil }
        let index = selected.flatMap { s in own.firstIndex { $0 === s } } ?? 0
        let tabs = own.map { ($0.url!, $0.keptIdentity) }
        let signature = tabs.map { "\($0.0) \($0.1?.id.uuidString ?? "")" }.joined(separator: "\n") + "\n\(index)"
        guard signature != savedSignature else { return }
        savedSignature = signature
        OpenTabs.save(tabs, selected: index)
    }

    @discardableResult
    func newTab(_ url: URL?, after: Tab? = nil, select shouldSelect: Bool = true, focus: Bool = true, restoring: Bool = false) -> Tab {
        let tab = Tab(delegate: self)
        let anchor = after ?? selected
        switch restoring ? .bottom : Preferences.shared.settings.newTabPosition {
        case .top:
            tabs.insert(tab, at: 0)
        case .below where anchor != nil:
            tabs.insert(tab, at: (tabs.firstIndex { $0 === anchor } ?? tabs.count - 1) + 1)
        case .below, .bottom:
            tabs.append(tab)
        }
        Extensions.shared.didOpen(tab)
        if let url { tab.load(url) }
        tabList.reload(tabs, selected: shouldSelect ? tab : selected)
        if shouldSelect { select(tab) }
        if url == nil, focus { focusAddress(nil) }
        saveTabs()
        return tab
    }

    /// A link from another app: into the blank tab if that's what's showing.
    func open(_ url: URL) {
        if let tab = selected, tab.url == nil, !tab.isLoading { tab.load(url); focusPage() } else { newTab(url) }
    }

    func select(_ tab: Tab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        let previous = selected
        if selected !== tab {
            selected?.webView.removeFromSuperview()
        }
        selected = tab
        tab.wake()
        if previous !== tab { Extensions.shared.didActivate(tab, previous: previous) }
        actionBar.reload()
        show(tab.webView)
        tabList.reload(tabs, selected: tab)
        refreshChrome()
        if tab.url == nil && tab.pending == nil { focusAddress(nil) } else { focusPage() }
        hideFind()
    }

    private func show(_ view: WKWebView) {
        guard view.superview !== content else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view, positioned: .below, relativeTo: pageHost)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    func close(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        if let url = tab.url, tab.opener == nil { closed.append(url) }
        for popup in tab.popups { close(popup) }
        tab.close()
        tabs.removeAll { $0 === tab }
        Extensions.shared.didClose(tab)
        if selected === tab {
            selected = nil
            if tabs.isEmpty {
                newTab(nil)
            } else if let opener = tab.opener, tabs.contains(where: { $0 === opener }) {
                select(opener)
            } else {
                select(tabs[min(i, tabs.count - 1)])
            }
        } else {
            tabList.reload(tabs, selected: selected)
        }
        saveTabs()
    }

    private func move(from: Int, to: Int) {
        guard tabs.indices.contains(from) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(0, to > from ? to - 1 : to), tabs.count))
        Extensions.shared.didMove(tab, from: from)
        tabList.reload(tabs, selected: selected)
        saveTabs()
    }

    private func refreshChrome() {
        updateNewTabPage()
        guard let tab = selected else { return }
        if !address.isEditing { address.show(tab.url) }
        progress.set(tab.isLoading ? tab.progress : 1)
        window?.title = tab.title.isEmpty ? "Core" : tab.title
    }

    // MARK: Address

    private func go(_ text: String) {
        let template = Preferences.shared.settings.searchTemplate
        switch Address.resolve(text, searchTemplate: template) {
        case .go(let url) where InternalPage.page(url) != nil:
            showInternal(url)
        case .go(let url):
            let tab = selected ?? newTab(nil)
            tab.load(url)
            focusPage()
        case .needsSearchEngine:
            address.flash("Set a search engine in Settings (⌘,)")
        case nil:
            break
        }
    }

    private func focusPage() {
        guard let tab = selected else { return }
        window?.makeFirstResponder(tab.webView)
        refreshChrome()
    }

    // MARK: Find

    private func hideFind() {
        findBar.dismiss()
        selected?.hideFind()
    }

    private func find(_ text: String, backwards: Bool) {
        guard let tab = selected else { return }
        tab.onFind = { [weak self] matches, current in self?.findBar.show(matches: matches, current: current) }
        tab.find(text, backwards: backwards)
    }

    // MARK: Actions

    @objc func newTabAction(_ sender: Any?) { newTab(nil) }

    /// ⌘Y: about://history.
    @objc func showHistory(_ sender: Any?) { showInternal(InternalPage.address("history")) }

    /// ⌘J: about://downloads.
    @objc func showDownloads(_ sender: Any?) { showInternal(InternalPage.address("downloads")) }

    /// ⇧⌘/: about://help.
    @objc func showHelp(_ sender: Any?) { showInternal(InternalPage.address("help")) }

    /// ⌘,: about://settings.
    @objc func showSettings(_ sender: Any?) { showInternal(InternalPage.address("settings")) }

    /// One of Core's own pages: the tab already showing it, else a new tab,
    /// or this one if it's blank.
    private func showInternal(_ address: URL) {
        if let open = tabs.first(where: { $0.url == address }) {
            select(open)
        } else if let tab = selected, tab.url == nil, tab.pending == nil {
            tab.load(address)
        } else {
            newTab(address)
        }
        focusPage()
    }
    @objc func focusAddress(_ sender: Any?) {
        guard sidebarShown || toggleCoreSidebarIfHidden() else { return }
        address.focus()
    }
    private func toggleCoreSidebarIfHidden() -> Bool { toggleCoreSidebar(nil); return true }
    @objc func closeTabAction(_ sender: Any?) {
        if let tab = selected { close(tab) }
    }
    @objc func reopenClosedTab(_ sender: Any?) {
        if let url = closed.popLast() { newTab(url) }
    }
    @objc func pasteAndGo(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        go(text)
    }
    @objc func reloadAction(_ sender: Any?) { selected?.reload() }
    @objc func stopAction(_ sender: Any?) { selected?.stop() }
    @objc func goBack(_ sender: Any?) { selected?.goBack() }
    @objc func goForward(_ sender: Any?) { selected?.goForward() }
    @objc func actualSize(_ sender: Any?) { selected?.webView.pageZoom = 1 }
    @objc func zoomIn(_ sender: Any?) { selected.map { $0.webView.pageZoom = min(3, $0.webView.pageZoom + 0.1) } }
    @objc func zoomOut(_ sender: Any?) { selected.map { $0.webView.pageZoom = max(0.3, $0.webView.pageZoom - 0.1) } }
    @objc func togglePersist(_ sender: Any?) { selected?.persist.toggle() }
    fileprivate private(set) var sidebarShown = true

    /// ⌘S. Hidden, the page has the whole window, traffic lights and all.
    @objc func toggleCoreSidebar(_ sender: Any?) {
        let show = !sidebarShown
        sidebarShown = show
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.animator().alphaValue = show ? 1 : 0
        }
        divider.isHidden = !show
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            context.allowsImplicitAnimation = true
            sidebarLeading.constant = show ? 0 : -width
            sidebar.animator().alphaValue = show ? 1 : 0
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// ⇧⌘S: the page as a web archive, wherever you say.
    @objc func savePage(_ sender: Any?) {
        guard let tab = selected, let window, tab.url != nil else { return }
        let panel = NSSavePanel()
        let name = (tab.title.isEmpty ? (tab.url?.host ?? "Page") : tab.title)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = name + ".webarchive"
        panel.allowedContentTypes = [.webArchive]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            tab.webView.createWebArchiveData { result in
                if case .success(let data) = result { try? data.write(to: url, options: .atomic) }
            }
        }
    }

    @objc func nextTab(_ sender: Any?) { step(1) }
    @objc func previousTab(_ sender: Any?) { step(-1) }
    private func step(_ by: Int) {
        guard let s = selected, let i = tabs.firstIndex(where: { $0 === s }), !tabs.isEmpty else { return }
        select(tabs[(i + by + tabs.count) % tabs.count])
    }
    @objc func selectTabNumber(_ sender: NSMenuItem) {
        guard !tabs.isEmpty else { return }
        select(sender.tag == 9 ? tabs[tabs.count - 1] : tabs[min(sender.tag - 1, tabs.count - 1)])
    }
    @objc func copyAddress(_ sender: Any?) {
        guard let url = selected?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    @objc func duplicateTab(_ sender: Any?) {
        if let tab = selected, let url = tab.url { newTab(url, after: tab) }
    }
    /// ⇧⌘I: Web Inspector for this tab's page.
    @objc func showInspector(_ sender: Any?) {
        guard let web = selected?.webView, selected?.internalPage == nil,
              let inspector = web.value(forKey: "_inspector") as? NSObject else { return }
        inspector.perform(NSSelectorFromString("show"))
    }

    @objc func showFind(_ sender: Any?) {
        findBar.present()
        findBar.focus()
    }
    @objc func findNext(_ sender: Any?) { find(findBar.text, backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(findBar.text, backwards: true) }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePersist(_:)):
            item.state = selected?.persist == true ? .on : .off
            return selected != nil
        case #selector(goBack(_:)): return selected?.canGoBack ?? false
        case #selector(goForward(_:)): return selected?.canGoForward ?? false
        case #selector(reopenClosedTab(_:)): return !closed.isEmpty
        case #selector(toggleCoreSidebar(_:)):
            item.title = sidebarShown ? "Hide Sidebar" : "Show Sidebar"
            return true
        default: return true
        }
    }
}

// MARK: TabDelegate

extension BrowserWindowController: TabDelegate {
    func tabDidChange(_ tab: Tab) {
        tabList.refresh(tab)
        saveTabs()
        if tab === selected { refreshChrome() }
    }

    func tab(_ tab: Tab, didReplace old: WKWebView?) {
        if tab === selected { show(tab.webView); window?.makeFirstResponder(tab.webView) }
    }

    func tab(_ tab: Tab, openInNewTab url: URL) {
        newTab(url, after: tab, select: false)
    }

    func tab(_ tab: Tab, didOpenPopup popup: Tab) {
        if let i = tabs.firstIndex(where: { $0 === tab }) { tabs.insert(popup, at: i + 1) } else { tabs.append(popup) }
        popup.delegate = self
        Extensions.shared.didOpen(popup)
        select(popup)
    }

    func tabWantsToClose(_ tab: Tab) { close(tab) }

    // MARK: Extension actions

    private func perform(_ action: WKWebExtension.Action, from button: NSView) {
        actionBar.anchor = button
        Extensions.shared.perform(action)
    }

    func tab(_ tab: Tab, allowCapture type: WKMediaCaptureType, for origin: String) async -> Bool {
        let what: String = switch type {
        case .camera: "your camera"
        case .microphone: "your microphone"
        default: "your camera and microphone"
        }
        return await Dialogs.ask(in: window, "Allow \(origin) to use \(what)?",
                                 detail: "Only for this page load. Core doesn't remember the answer.",
                                 yes: "Allow", no: "Don't Allow")
    }

    func tab(_ tab: Tab, saveDownload name: String) async -> URL? {
        #if DEBUG
        if let folder = UserDefaults.standard.string(forKey: "coreStore"), UserDefaults.standard.bool(forKey: "coreSelfTest") {
            return URL(fileURLWithPath: folder).appendingPathComponent(name)
        }
        #endif
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard let window else { return nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }

    func tab(_ tab: Tab, runAlert message: String) async {
        _ = await Dialogs.ask(in: window, tab.url?.host ?? "This page", detail: message, yes: "OK", no: nil)
    }

    func tab(_ tab: Tab, runConfirm message: String) async -> Bool {
        await Dialogs.ask(in: window, tab.url?.host ?? "This page", detail: message, yes: "OK", no: "Cancel")
    }

    func tab(_ tab: Tab, runPrompt message: String, defaultText: String?) async -> String? {
        await Dialogs.prompt(in: window, tab.url?.host ?? "This page", detail: message, text: defaultText ?? "")
    }

    func tab(_ tab: Tab, chooseFiles multiple: Bool, directories: Bool) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = directories
        panel.canChooseFiles = true
        guard let window else { return nil }
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }
}

extension BrowserWindowController: ExtensionHost {
    var extensionTabs: [Tab] { tabs }
    var extensionActiveTab: Tab? { selected }
    var extensionWindowFrame: CGRect { window?.frame ?? .zero }

    func extensionOpen(_ url: URL?, active: Bool) -> Tab {
        newTab(url, select: active)
    }

    func extensionSelect(_ tab: Tab) { select(tab) }
    func extensionClose(_ tab: Tab) { close(tab) }
    func extensionActionsChanged() { actionBar.reload() }

    func extensionPresent(_ action: WKWebExtension.Action) {
        guard let popover = action.popupPopover else { return }
        action.popupWebView?.underPageBackgroundColor = .white
        action.popupWebView?.setValue(true, forKey: "drawsBackground")
        self.popover?.close()
        let anchor = actionBar.anchor ?? actionBar
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        self.popover = popover
    }
}

#if DEBUG
extension BrowserWindowController {
    var addressFieldForTesting: AddressField { address }
    var selectedWebViewForTesting: NSView { selected?.webView ?? content }
    var sidebarShownForTesting: Bool { sidebarShown }
    var selectedTab: Tab? { selected }
    var pageShownForTesting: String? { pageHost.isHidden ? nil : hostedPage }
    var pageHostForTesting: NSView { pageHost }
    var downloadTilesForTesting: [DownloadTile] { ((downloads.subviews.first as? NSStackView)?.arrangedSubviews ?? []).compactMap { $0 as? DownloadTile } }
    var downloadRowsForTesting: Int { downloads.isHidden ? 0 : downloads.subviews.first?.subviews.count ?? 0 }
    var fillsForTesting: Bool { fills && sidebar.isFrosted && !backdrop.isHidden && backdrop.frame.minX == 0 && backdrop.frame.width > content.frame.width }
    var tabTableForTesting: NSTableView? { tabList.documentView as? NSTableView }
    var newTabPageShownForTesting: Bool { !backdrop.isHidden && backdrop.alphaValue > 0.5 }
    func mouseButtonForTesting(_ number: Int) { mouseButton(number) }
    func swipeForTesting(_ phase: NSEvent.Phase, dx: CGFloat) { follow(phase, dx: dx, dy: 0) }
}
#endif

/// Core's shortcuts come before the page's: WKWebView takes every ⌘-key
/// it is offered (⌘S, ⌘L…) and hands back only some of them.
final class BrowserWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
