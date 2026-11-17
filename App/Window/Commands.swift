import AppKit
import BrowserKit
import UniformTypeIdentifiers

/// What the menu bar's commands do. Every one is aimed here (see
/// `Menus.aim`), so it works whatever has the keyboard.
@MainActor
final class Commands: NSObject, NSMenuItemValidation {
    weak var shell: BrowserWindowController?
    private var browser: Browser? { shell?.browser }
    private var tab: Tab? { browser?.selected }

    // MARK: Browser's own pages

    /// ⌘,: about://settings.
    @objc func showSettings(_ sender: Any?) { shell?.show(.settings) }
    /// about://userscripts.
    @objc func showUserscripts(_ sender: Any?) { shell?.show(.userscripts) }
    /// ⌘H: about://history.
    @objc func showHistory(_ sender: Any?) { shell?.show(.history) }
    /// ⌘J: about://downloads.
    @objc func showDownloads(_ sender: Any?) { shell?.show(.downloads) }
    /// ⇧⌘/: about://help.
    @objc func showHelp(_ sender: Any?) { shell?.show(.help) }

    /// The command that shows `page`, so about://help can read its keys
    /// from the menus.
    static func showing(_ page: InternalPage) -> Selector {
        switch page {
        case .history: #selector(showHistory(_:))
        case .downloads: #selector(showDownloads(_:))
        case .settings: #selector(showSettings(_:))
        case .userscripts: #selector(showUserscripts(_:))
        case .help: #selector(showHelp(_:))
        }
    }

    // MARK: File

    @objc func newTab(_ sender: Any?) { browser?.newTab() }
    @objc func focusAddress(_ sender: Any?) { shell?.focusAddress() }

    /// ⇧⌘S: the page as a web archive, wherever you say.
    @objc func savePage(_ sender: Any?) {
        guard let tab, let window = shell?.window, tab.url != nil else { return }
        let panel = NSSavePanel()
        let name = (tab.title.isEmpty ? (tab.url?.host ?? "Page") : tab.title)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = name + ".webarchive"
        panel.allowedContentTypes = [.webArchive]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let webView = tab.webView
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            webView.createWebArchiveData { result in
                if case .success(let data) = result { try? data.write(to: url, options: .atomic) }
            }
        }
    }

    /// ⌘W. A Persist tab asks first.
    @objc func closeTab(_ sender: Any?) {
        guard let browser, let tab else { return }
        Task { await browser.closeAsking(tab) }
    }

    @objc func reopenClosedTab(_ sender: Any?) { browser?.reopenClosedTab() }

    // MARK: Edit

    @objc func pasteAndGo(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        shell?.go(text)
    }

    @objc func showFind(_ sender: Any?) {
        shell?.pageArea.findBar.present()
        shell?.pageArea.findBar.focus()
    }

    @objc func findNext(_ sender: Any?) { shell?.pageArea.findBar.search(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { shell?.pageArea.findBar.search(backwards: true) }

    // MARK: View

    @objc func reload(_ sender: Any?) { tab?.reload() }
    @objc func stop(_ sender: Any?) { tab?.stop() }
    @objc func actualSize(_ sender: Any?) { tab?.webView.pageZoom = 1 }
    @objc func zoomIn(_ sender: Any?) { tab.map { $0.webView.pageZoom = min(3, $0.webView.pageZoom + 0.1) } }
    @objc func zoomOut(_ sender: Any?) { tab.map { $0.webView.pageZoom = max(0.3, $0.webView.pageZoom - 0.1) } }

    /// ⌘S. Not `toggleSidebar:`, which is NSWindow's own.
    @objc func toggleBrowserSidebar(_ sender: Any?) { shell?.sidebar.toggle() }

    /// ⇧⌘I: Web Inspector for this tab's page, open or closed.
    @objc func toggleInspector(_ sender: Any?) {
        guard let tab, tab.page == nil, let inspector = tab.webView.value(forKey: "_inspector") as? NSObject else { return }
        tab.webView.isInspectable = true
        let shown = inspector.value(forKey: "isVisible") as? Bool == true
        inspector.perform(NSSelectorFromString(shown ? "close" : "show"))
    }

    // MARK: History

    @objc func goBack(_ sender: Any?) { tab?.goBack() }
    @objc func goForward(_ sender: Any?) { tab?.goForward() }

    // MARK: Tab

    @objc func togglePersist(_ sender: Any?) { tab?.persist.toggle() }
    @objc func nextTab(_ sender: Any?) { browser?.selectTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { browser?.selectTab(offset: -1) }
    /// ⌘1 to ⌘9: the item's tag is the number.
    @objc func selectTabNumber(_ sender: NSMenuItem) { browser?.selectTab(number: sender.tag) }

    @objc func copyAddress(_ sender: Any?) {
        guard let url = tab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func duplicateTab(_ sender: Any?) {
        if let tab { browser?.duplicate(tab) }
    }

    // MARK: What applies now

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePersist(_:)):
            item.state = tab?.persist == true ? .on : .off
            return tab != nil
        case #selector(goBack(_:)): return tab?.canGoBack ?? false
        case #selector(goForward(_:)): return tab?.canGoForward ?? false
        case #selector(reopenClosedTab(_:)): return browser?.canReopenClosedTab ?? false
        case #selector(toggleBrowserSidebar(_:)):
            item.title = shell?.sidebar.isShown == false ? "Show Sidebar" : "Hide Sidebar"
            return true
        default: return true
        }
    }
}
