import AppKit
import CoreKit
import WebKit

/// The one window: tabs down the left, the page on the right, one field
/// above the tabs.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private(set) var tabs: [Tab] = []
    private(set) var selected: Tab?
    private var closed: [URL] = []

    private let sidebar = NSVisualEffectView()
    private let address = AddressField()
    private let tabList = TabListView()
    private let actionBar = ActionBar()
    private let content = NSView()
    private let progress = ProgressLine()
    private let notice = NSTextField(labelWithString: "")
    private let findBar = FindBar()
    private var sidebarWidth: NSLayoutConstraint!
    private var popover: NSPopover?
    private static let width: CGFloat = 240

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 600, height: 400)
        window.setFrameAutosaveName("Core")
        if window.frame.origin == .zero { window.center() }
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        layout()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func layout() {
        guard let root = window?.contentView else { return }
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        address.onSubmit = { [weak self] text in self?.go(text) }
        address.onEscape = { [weak self] in self?.focusPage() }

        tabList.onSelect = { [weak self] tab in self?.select(tab) }
        tabList.onClose = { [weak self] tab in self?.close(tab) }
        tabList.onPersist = { tab in tab.persist.toggle() }
        tabList.onMove = { [weak self] from, to in self?.move(from: from, to: to) }
        tabList.onDuplicate = { [weak self] tab in if let url = tab.url { self?.newTab(url, after: tab) } }
        tabList.onCloseOthers = { [weak self] tab in
            guard let self else { return }
            for other in self.tabs where other !== tab { self.close(other) }
        }

        let newTab = NSButton(title: "New Tab", image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!, target: self, action: #selector(newTabAction(_:)))
        newTab.bezelStyle = .accessoryBarAction
        newTab.isBordered = false
        newTab.imagePosition = .imageLeading
        newTab.contentTintColor = .secondaryLabelColor
        newTab.font = .systemFont(ofSize: 12)

        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .systemOrange
        notice.lineBreakMode = .byWordWrapping
        notice.maximumNumberOfLines = 3
        notice.isHidden = Engine.isPatched
        notice.stringValue = "System WebKit: fingerprint protection is not active in this build."

        actionBar.onClick = { [weak self] action, button in self?.perform(action, from: button) }

        for view in [sidebar, content, address, actionBar, tabList, newTab, notice, progress, findBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(sidebar)
        root.addSubview(content)
        sidebar.addSubview(address)
        sidebar.addSubview(actionBar)
        sidebar.addSubview(tabList)
        sidebar.addSubview(newTab)
        sidebar.addSubview(notice)
        content.addSubview(progress)
        content.addSubview(findBar)
        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFind() }
        findBar.onSearch = { [weak self] text, back in self?.find(text, backwards: back) }

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: Self.width)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidth,

            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            address.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 40),
            address.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            address.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            address.heightAnchor.constraint(equalToConstant: 28),

            actionBar.topAnchor.constraint(equalTo: address.bottomAnchor, constant: 6),
            actionBar.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            actionBar.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.trailingAnchor, constant: -10),

            tabList.topAnchor.constraint(equalTo: actionBar.bottomAnchor, constant: 6),
            tabList.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 6),
            tabList.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -6),
            tabList.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -6),

            notice.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            notice.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            notice.bottomAnchor.constraint(equalTo: newTab.topAnchor, constant: -4),

            newTab.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            newTab.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -10),

            progress.topAnchor.constraint(equalTo: content.topAnchor),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),

            findBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
        ])
    }

    // MARK: Tabs

    func restore() {
        let saved = OpenTabs.restore()
        for url in saved.urls { newTab(nil, select: false, focus: false).restore(url) }
        if tabs.isEmpty {
            newTab(nil)
        } else {
            select(tabs[min(max(saved.selected, 0), tabs.count - 1)])
        }
        saveTabs()
    }

    func saveTabs() {
        let urls = tabs.filter { $0.opener == nil }.compactMap(\.url)
        let index = selected.flatMap { s in tabs.filter { $0.opener == nil }.firstIndex { $0 === s } } ?? 0
        OpenTabs.save(urls, selected: index)
    }

    @discardableResult
    func newTab(_ url: URL?, after: Tab? = nil, select shouldSelect: Bool = true, focus: Bool = true) -> Tab {
        let tab = Tab(delegate: self)
        let anchor = after ?? selected
        if let anchor, let i = tabs.firstIndex(where: { $0 === anchor }) {
            tabs.insert(tab, at: i + 1)
        } else {
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
        if selected !== tab { selected?.webView.removeFromSuperview() }
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
        content.addSubview(view, positioned: .below, relativeTo: progress)
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
        tabList.reload(tabs, selected: selected)
        saveTabs()
    }

    private func refreshChrome() {
        guard let tab = selected else { return }
        if !address.isEditing { address.stringValue = tab.url?.absoluteString ?? "" }
        progress.set(tab.isLoading ? tab.progress : 1)
        window?.title = tab.title.isEmpty ? "Core" : tab.title
    }

    // MARK: Address

    private func go(_ text: String) {
        let template = Preferences.shared.settings.searchTemplate
        switch Address.resolve(text, searchTemplate: template) {
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
        findBar.isHidden = true
        selected?.webView.evaluateJavaScript("void 0") // nothing; WebKit clears the highlight on its own
    }

    private func find(_ text: String, backwards: Bool) {
        guard let web = selected?.webView, !text.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        web.find(text, configuration: config) { [weak self] result in
            self?.findBar.matched(result.matchFound)
        }
    }

    // MARK: Actions

    @objc func newTabAction(_ sender: Any?) { newTab(nil) }
    @objc func focusAddress(_ sender: Any?) {
        guard sidebarWidth.constant > 0 || toggleSidebarIfHidden() else { return }
        window?.makeFirstResponder(address)
        address.currentEditor()?.selectAll(nil)
    }
    private func toggleSidebarIfHidden() -> Bool { toggleSidebar(nil); return true }
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
    @objc func toggleSidebar(_ sender: Any?) {
        sidebarWidth.animator().constant = sidebarWidth.constant > 0 ? 0 : Self.width
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
    @objc func showFind(_ sender: Any?) {
        findBar.isHidden = false
        findBar.focus()
    }
    @objc func findNext(_ sender: Any?) { find(findBar.text, backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(findBar.text, backwards: true) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePersist(_:)):
            item.state = selected?.persist == true ? .on : .off
            return selected != nil
        case #selector(goBack(_:)): return selected?.canGoBack ?? false
        case #selector(goForward(_:)): return selected?.canGoForward ?? false
        case #selector(reopenClosedTab(_:)): return !closed.isEmpty
        case #selector(toggleSidebar(_:)):
            item.title = sidebarWidth.constant > 0 ? "Hide Sidebar" : "Show Sidebar"
            return true
        default: return true
        }
    }
}

// MARK: TabDelegate

extension BrowserWindowController: TabDelegate {
    func tabDidChange(_ tab: Tab) {
        tabList.refresh(tab)
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

    func tab(_ tab: Tab, allowDownload name: String, size: Int64?) async -> Bool {
        let detail = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown size"
        return await Dialogs.ask(in: window, "Download “\(name)”?",
                                 detail: "\(detail) · from \(tab.url?.host ?? "this page") · saved to Downloads",
                                 yes: "Download", no: "Cancel")
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
        guard let web = action.popupWebView else { return }
        popover?.close()
        let controller = NSViewController()
        controller.view = web
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: max(web.frame.width, 360), height: max(web.frame.height, 480))
        popover.delegate = PopoverCloser.shared
        PopoverCloser.shared.action = action
        let anchor = actionBar.anchor ?? actionBar
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        self.popover = popover
    }
}

/// Tells the extension its popup went away, so it can tidy up.
@MainActor
final class PopoverCloser: NSObject, NSPopoverDelegate {
    static let shared = PopoverCloser()
    var action: WKWebExtension.Action?
    func popoverDidClose(_ notification: Notification) {
        action?.closePopup()
        action = nil
    }
}
