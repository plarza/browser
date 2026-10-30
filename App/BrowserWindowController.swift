import AppKit
import Combine
import SwiftUI
import BrowserKit
import UniformTypeIdentifiers
import WebKit

/// Browser's tab, not SwiftUI's.
typealias Tab = BrowserKit.Tab

/// The one window: tabs down the left, the page on the right, one field
/// above the tabs.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private(set) var tabs: [Tab] = []
    private(set) var selected: Tab?
    private var closed: [URL] = []

    let sidebar = Surface()
    let address = AddressField()
    let tabList = TabListView()
    private let actionBar = ActionBar()
    let content = Surface()
    private let progress = ProgressLine()
    private let findBar = FindBar()
    private let divider = SidebarDivider()
    private var sidebarWidth: NSLayoutConstraint!
    private var sidebarLeading: NSLayoutConstraint!
    private var popover: NSPopover?
    /// Behind a blank tab: the new tab page.
    let backdrop = NewTabBackdrop()
    let downloads = DownloadDock()
    fileprivate let shade = SidebarShadow()
    /// Browser's own pages, native, where the web view would be.
    let pageHost = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) var hostedPage: String?
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
        // Every launch fills the screen, short of the menu bar and Dock; not
        // full screen.
        if let screen = NSScreen.main { window.setFrame(screen.visibleFrame, display: false) }
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
        pageHost.isHidden = true
        content.addPinned(pageHost, below: progress)
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
    private(set) var fills = false

    /// The new tab page's picture under the whole window, seen through a
    /// frosted sidebar.
    private func fill(_ on: Bool) {
        guard on != fills else { return }
        fills = on
        backdropLeading.page.isActive = !on
        backdropLeading.window.isActive = on
        sidebar.isClear = on
        backdrop.glassWidth = on ? width : 0
        updateNewTabPage()
    }

    /// The new tab page shows while the tab has nothing in it.
    private func updateNewTabPage() {
        let blank = selected.map { $0.url == nil && $0.pending == nil && !$0.isLoading } ?? false
        let page = selected?.internalPage
        selected?.view.isHidden = blank || page != nil
        content.isClear = blank
        backdrop.isHidden = !blank && !fills
        backdrop.alphaValue = 1
        pageHost.isHidden = page == nil
        if let page, page != hostedPage {
            pageHost.rootView = Pages.view(page) { [weak self] url in self?.selected?.load(url) }
        }
        hostedPage = page
    }

    /// The window's local event monitors, kept for as long as it is.
    private var monitors: [Any?] = []

    /// ⇧⌘/ is macOS's own "search the Help menu"; in Browser it opens
    /// about://help, before the system can take it.
    private func watchHelpKey() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { () -> NSEvent? in
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
                guard let self, event.window === self.window, mods == [.command, .shift],
                      event.charactersIgnoringModifiers == "/" || event.charactersIgnoringModifiers == "?" || event.keyCode == 44
                else { return event }
                self.showHelp(nil)
                return nil
            }
        })
    }

    private func watchDownloads() {
        downloads.onShowAll = { [weak self] in self?.showDownloads(nil) }
    }

    /// A mouse's back and forward buttons do what ⌘[ and ⌘] do. WebKit
    /// would otherwise take them for its own lists, which a wipe empties.
    private func watchMouseButtons() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { () -> NSEvent? in
                guard let self, event.window === self.window, event.buttonNumber == 3 || event.buttonNumber == 4 else { return event }
                if event.type == .otherMouseDown { self.mouseButton(event.buttonNumber) }
                return nil
            }
        })
    }

    func mouseButton(_ number: Int) {
        if number == 3 { selected?.goBack() } else { selected?.goForward() }
    }

    /// Two-finger swipes left and right go back and forward, as in Safari.
    /// Browser keeps its own back and forward lists (a wipe swaps the web view
    /// out), so the swipe is followed here, from the scroll gesture's phases:
    /// going back, the page follows the fingers off to the right, a picture
    /// of the page before coming out from under it; going forward, the page
    /// after slides in over it. Letting go far enough, or with a flick,
    /// finishes, and the picture stays until the next page draws.
    private var swipe: (back: Bool, distance: CGFloat, last: CGFloat, picture: NSImageView)?
    private var loading: Set<UUID> = []

    private func watchSwipes() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window,
                      self.content.bounds.contains(self.content.convert(event.locationInWindow, from: nil))
                else { return }
                // The page came to rest: its picture, for swiping back to it.
                if event.phase == .ended || event.momentumPhase == .ended { self.captureSoon() }
                guard NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return }
                self.follow(event.phase, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
            }
            return event
        })
    }

    func follow(_ phase: NSEvent.Phase, dx: CGFloat, dy: CGFloat) {
        guard let tab = selected else { return }
        switch phase {
        case .began:
            guard abs(dx) > abs(dy) * 2 else { return }
            // Fingers moving right (a positive delta) mean back.
            let back = dx > 0
            guard back ? tab.canGoBack : tab.canGoForward, tab.internalPage == nil, !tab.view.isHidden else { return }
            capture(tab)
            let picture = NSImageView(frame: content.bounds)
            picture.imageScaling = .scaleAxesIndependently
            picture.image = pictures[Self.key(tab, tab.index + (back ? -1 : 1))]
            picture.wantsLayer = true
            picture.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            content.addSubview(picture, positioned: back ? .below : .above, relativeTo: tab.view)
            let top = back ? tab.view : picture
            top.wantsLayer = true
            top.layer?.shadowColor = NSColor.black.cgColor
            top.layer?.shadowOpacity = 0.2
            top.layer?.shadowRadius = 12
            top.layer?.shadowPath = CGPath(rect: content.bounds, transform: nil)
            swipe = (back, abs(dx), abs(dx), picture)
            placeSwipe()
        case .changed:
            guard let current = swipe else { return }
            let step = current.back ? dx : -dx
            swipe?.distance = min(content.bounds.width, max(0, current.distance + step))
            swipe?.last = step
            placeSwipe()
        case .ended, .cancelled:
            guard let current = swipe else { return }
            let width = content.bounds.width
            let done = phase == .ended && (current.distance > width / 4 || current.last > 6 && current.distance > 40)
            swipe?.distance = done ? width : 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                placeSwipe(animated: true)
            } completionHandler: {
                MainActor.assumeIsolated { self.endSwipe(done: done) }
            }
        default:
            break
        }
    }

    /// The page the fingers move, and under it, a third as far, the other.
    private func placeSwipe(animated: Bool = false) {
        guard let swipe, let page = selected?.view else { return }
        let width = content.bounds.width, x = swipe.distance
        let (moving, under) = swipe.back ? (x, -(width - x) / 3) : (-x / 3, width - x)
        (animated ? page.animator() : page).setFrameOrigin(NSPoint(x: moving, y: 0))
        (animated ? swipe.picture.animator() : swipe.picture).setFrameOrigin(NSPoint(x: under, y: 0))
    }

    private func endSwipe(done: Bool) {
        guard let swipe, let tab = selected else { return }
        self.swipe = nil
        tab.view.frame = content.bounds
        tab.view.layer?.shadowOpacity = 0
        swipe.picture.layer?.shadowOpacity = 0
        swipe.picture.removeFromSuperview()
        guard done else { return }
        // The picture stays over the page until the next one draws.
        tab.view.hold(swipe.picture)
        if swipe.back { tab.goBack() } else { tab.goForward() }
    }

    // MARK: Pictures

    /// Pictures of pages by tab and place in its back and forward list,
    /// for swipes: the latest few, taken by WebKit off the main thread.
    private var pictures: [String: NSImage] = [:]
    private var pictureOrder: [String] = []
    private var settle: Task<Void, Never>?

    private static func key(_ tab: Tab, _ index: Int) -> String { "\(tab.id) \(index)" }

    private func captureSoon() {
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled, let self, let tab = self.selected { self.capture(tab) }
        }
    }

    private func capture(_ tab: Tab) {
        guard tab.index >= 0, tab.url != nil, tab.internalPage == nil, tab.view.window != nil else { return }
        let key = Self.key(tab, tab.index), web = tab.webView
        Task { [weak self] in
            guard let image = try? await web.takeSnapshot(configuration: nil), let self else { return }
            self.pictures[key] = image
            self.pictureOrder.removeAll { $0 == key }
            self.pictureOrder.append(key)
            while self.pictureOrder.count > 8 { self.pictures[self.pictureOrder.removeFirst()] = nil }
        }
    }

    /// A click anywhere but the field, while editing it, leaves it: on the
    /// page, focus goes to the page; elsewhere, to nothing.
    private func watchClicks() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
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
        })
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
        tabList.onClose = { [weak self] tab in self?.closeAsking(tab) }
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
        let kept = Set(saved.tabs.compactMap { $0.kept })
        Task { await Identity.removeOrphans(keeping: kept) }
        if tabs.isEmpty {
            newTab(nil)
        } else {
            select(tabs[min(max(saved.selected, 0), tabs.count - 1)])
        }
        saveTabs()
    }

    func saveTabs() { OpenTabs.save(tabs, selected: selected) }

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
            selected?.view.removeFromSuperview()
        }
        selected = tab
        tab.wake()
        if previous !== tab { Extensions.shared.didActivate(tab, previous: previous) }
        actionBar.reload()
        show(tab.view)
        tabList.reload(tabs, selected: tab)
        refreshChrome()
        if tab.url == nil && tab.pending == nil { focusAddress(nil) } else { focusPage() }
        hideFind()
    }

    private func show(_ view: PageView) {
        guard view.superview !== content else { return }
        // Web Inspector resizes the inspected view when docked. Edge
        // constraints would force it back over the inspector on every layout.
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = content.bounds
        content.addSubview(view, positioned: .below, relativeTo: pageHost)
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
        window?.title = tab.title.isEmpty ? "Browser" : tab.title
    }

    // MARK: Address

    private func go(_ text: String) {
        let template = Preferences.shared.settings.searchTemplate
        switch Address.resolve(text, searchTemplate: template) {
        case .go(let url) where InternalPage.page(url) != nil:
            showInternal(url)
        case .go(let url):
            let tab = selected ?? newTab(nil)
            // An address counts as typed in History; a search or a bang doesn't.
            let typed = Address.url(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            tab.load(url, as: typed ? .typed : .link)
            focusPage()
        case .needsSearchEngine:
            address.flash("No search engine set (⌘,)")
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

    /// One of Browser's own pages: the tab already showing it, else a new tab,
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
        if !sidebarShown { toggleBrowserSidebar(nil) }
        address.focus()
    }
    @objc func closeTabAction(_ sender: Any?) {
        if let tab = selected { closeAsking(tab) }
    }

    /// Closing a Persist tab deletes its jar, logins and all, so a person
    /// closing one is asked first. Pages and extensions closing tabs aren't.
    private func closeAsking(_ tab: Tab) {
        guard tab.persist, tab.opener == nil else { return close(tab) }
        let name = tab.title.isEmpty ? tab.url?.host ?? "this tab" : tab.title
        Task {
            guard await Dialogs.ask(in: window, "Close “\(name)”?", detail: "Its cookies and site data will be deleted.",
                                    yes: "Close Tab") else { return }
            close(tab)
        }
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
    private(set) var sidebarShown = true

    /// ⌘S. Hidden, the page has the whole window, traffic lights and all.
    @objc func toggleBrowserSidebar(_ sender: Any?) {
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
    /// ⇧⌘I: Web Inspector for this tab's page, open or closed.
    @objc func toggleInspector(_ sender: Any?) {
        guard let web = selected?.webView, selected?.internalPage == nil,
              let inspector = web.value(forKey: "_inspector") as? NSObject else { return }
        web.isInspectable = true
        let shown = inspector.value(forKey: "isVisible") as? Bool == true
        inspector.perform(NSSelectorFromString(shown ? "close" : "show"))
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
        case #selector(toggleBrowserSidebar(_:)):
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
        if tab.isLoading { loading.insert(tab.id) } else if loading.remove(tab.id) != nil, tab === selected { captureSoon() }
    }

    func tab(_ tab: Tab, didReplace old: WKWebView?) {
        if tab === selected { window?.makeFirstResponder(tab.webView) }
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
        return await Dialogs.ask(in: window, "Allow \(origin) to use \(what)?", yes: "Allow", no: "Don't Allow")
    }

    func tab(_ tab: Tab, saveDownload name: String) async -> URL? {
        #if DEBUG
        if let folder = UserDefaults.standard.string(forKey: "browserStore"), UserDefaults.standard.bool(forKey: "browserSelfTest") {
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
        await Dialogs.ask(in: window, tab.url?.host ?? "This page", detail: message, yes: "OK")
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

/// Browser's shortcuts come before the page's: WKWebView takes every ⌘-key
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
