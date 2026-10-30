import BrowserKit
import SwiftUI
import WebKit

/// BrowserKit's, not SwiftUI's.
typealias Tab = BrowserKit.Tab

/// The tabs, which one is showing, and what's on screen around it. The
/// rules live in BrowserKit; this only arranges them for one hand.
@MainActor @Observable
final class Browser {
    private(set) var tabs: [Tab] = []
    private(set) var selected: Tab?
    /// The address sheet is up: for the tab showing, or for a tab that
    /// doesn't exist until you go somewhere.
    var editing: Editing?
    var showingSettings = false
    /// Scrolling down shrinks the bar to the site's name.
    var barCollapsed = false
    /// 0 with the page full screen, 1 with it shrunk into its card in the
    /// grid. Springs and the finger move it; everything else follows.
    var gridProgress: CGFloat = 0
    /// How far the page is being dragged sideways, towards the next tab.
    var pageOffset: CGFloat = 0
    /// Bumped when a tab's title, address, loading or Persist changes.
    private(set) var revision = 0
    /// The selected tab's loading, apart, so only the bar's line redraws.
    private(set) var progress: Double?
    var notice: String?

    enum Editing { case current, newTab }

    /// The last picture of each tab, for the grid and the tab stack.
    private(set) var snapshots: [UUID: UIImage] = [:]
    /// Where each card sits on screen, for the page to shrink into. Written
    /// during layout, so nothing redraws for it.
    @ObservationIgnored var cardFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var states: [UUID: String] = [:]
    var gridShown: Bool { gridProgress >= 1 }

    // MARK: Tabs

    func restore() {
        let saved = OpenTabs.restore()
        for saved in saved.tabs {
            let tab = Tab(delegate: self)
            tab.restore(saved.url, kept: saved.kept)
            tabs.append(tab)
        }
        Task { await Identity.removeOrphans(keeping: Set(saved.tabs.compactMap { $0.kept })) }
        if !tabs.isEmpty { select(tabs[min(max(saved.selected, 0), tabs.count - 1)]) }
    }

    func saveTabs() { OpenTabs.save(tabs, selected: selected) }

    /// Tabs only ever start with somewhere to go: + asks first, so there
    /// are no blank tabs to tidy up.
    @discardableResult
    func newTab(_ url: URL, as kind: History.Kind = .link, after: Tab? = nil) -> Tab {
        let tab = Tab(delegate: self)
        let anchor = after ?? selected
        switch Preferences.shared.settings.newTabPosition {
        case .top:
            tabs.insert(tab, at: 0)
        case .below where anchor != nil:
            tabs.insert(tab, at: (tabs.firstIndex { $0 === anchor } ?? tabs.count - 1) + 1)
        case .below, .bottom:
            tabs.append(tab)
        }
        tab.load(url, as: kind)
        select(tab)
        return tab
    }

    /// A link from another app.
    func open(_ url: URL) {
        newTab(url)
        showPage()
    }

    /// `picture`: take the leaving tab's picture now, while it's on screen.
    /// A swipe took it already, before the page was hidden.
    func select(_ tab: Tab, picture: Bool = true) {
        guard tabs.contains(where: { $0 === tab }), selected !== tab else { return }
        if picture, let old = selected { snapshot(old) }
        selected = tab
        tab.wake()
        barCollapsed = false
        progress = tab.isLoading ? tab.progress : nil
        revision += 1
        saveTabs()
    }

    var neighbours: (previous: Tab?, next: Tab?) {
        guard let tab = selected, let i = tabs.firstIndex(where: { $0 === tab }) else { return (nil, nil) }
        return (i > 0 ? tabs[i - 1] : nil, i + 1 < tabs.count ? tabs[i + 1] : nil)
    }

    func close(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        for popup in tab.popups { close(popup) }
        tab.close()
        tabs.remove(at: i)
        snapshots[tab.id] = nil
        cardFrames[tab.id] = nil
        states[tab.id] = nil
        if selected === tab {
            selected = nil
            if let opener = tab.opener, tabs.contains(where: { $0 === opener }) {
                select(opener)
            } else if !tabs.isEmpty {
                select(tabs[min(i, tabs.count - 1)])
            }
        }
        // The last one gone: the grid, empty, with its address bar.
        if tabs.isEmpty { showGrid() }
        revision += 1
        saveTabs()
    }

    /// Closing a Persist tab deletes its jar, logins and all, so a person
    /// closing one is asked first. Pages closing tabs aren't.
    func closeAsking(_ tab: Tab) async -> Bool {
        if tab.persist, tab.opener == nil {
            let name = tab.title.isEmpty ? tab.url?.host ?? "this tab" : tab.title
            guard await Dialogs.confirm("Close “\(name)”?\nIts cookies and site data will be deleted.",
                                        ok: "Close Tab", cancel: "Cancel", destructive: true) else { return false }
        }
        withAnimation(Motion.snappy) { close(tab) }
        return true
    }

    // MARK: Page and grid

    /// The page shrinks into its card. `velocity` is the finger's, in
    /// progress per second, so a flick carries on at its own speed.
    func showGrid(velocity: CGFloat = 0) {
        if let selected { snapshot(selected) }
        barCollapsed = false
        withAnimation(Motion.spring(velocity: velocity)) { gridProgress = 1 }
    }

    /// The selected card (or `tab`'s) grows back into the page.
    func showPage(_ tab: Tab? = nil, velocity: CGFloat = 0) {
        if let tab { select(tab) }
        withAnimation(Motion.spring(velocity: velocity)) { gridProgress = 0 }
    }

    /// What the tab looks like now, drawn from the screen at once, so it's
    /// there for the very first frame of whatever needs it.
    func snapshot(_ tab: Tab) {
        let view = tab.webView
        guard view.window != nil, tab.url != nil, tab.internalPage == nil, !view.bounds.isEmpty else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        snapshots[tab.id] = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }

    /// The address sheet up or down. The page's picture is taken first, to
    /// step back in its place.
    func edit(_ target: Editing?) {
        if target != nil, editing == nil, let selected { snapshot(selected) }
        withAnimation(Motion.spring()) { editing = target }
    }

    // MARK: Swiping between tabs

    /// The finger let go of the address bar: on to the tab that side, or
    /// back. The new tab is selected at once, so the address and the stack
    /// change as the pictures carry on to rest.
    func endSwipe(translation: CGFloat, velocity: CGFloat, width: CGFloat) {
        let (previous, next) = neighbours
        let projected = translation + velocity * 0.15
        let target = projected > width / 3 ? previous : projected < -width / 3 ? next : nil
        if let target {
            let step = (target === previous ? 1 : -1) * (width + PageArea.gap)
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                select(target, picture: false)
                pageOffset -= step
            }
        }
        // The next tick: begun in the same one as the re-basing above,
        // SwiftUI leaves the slide where it started.
        let distance = -pageOffset
        DispatchQueue.main.async {
            withAnimation(Motion.spring(velocity: distance == 0 ? 0 : velocity / distance)) { self.pageOffset = 0 }
        }
    }

    // MARK: Address

    /// What was typed (or picked) in the address sheet.
    func go(_ text: String, picked: String? = nil) {
        if let picked { History.shared.picked(picked, after: text) }
        let target = picked ?? text
        switch Address.resolve(target, searchTemplate: Preferences.shared.settings.searchTemplate) {
        case .go(let url):
            // An address counts as typed in History; a search or a bang doesn't.
            let typed = picked != nil || Address.url(from: target.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
            if editing == .current, let tab = selected {
                tab.load(url, as: typed ? .typed : .link)
            } else {
                newTab(url, as: typed ? .typed : .link)
            }
            edit(nil)
            showPage()
        case .needsSearchEngine:
            notice = "No search engine set. Add one in Settings."
        case nil:
            break
        }
    }
}

/// One feel for every move: quick, settled, carrying the finger's speed.
enum Motion {
    static func spring(velocity: CGFloat = 0) -> Animation {
        .interpolatingSpring(duration: 0.34 * slow, bounce: 0.08, initialVelocity: velocity / slow)
    }
    static var snappy: Animation { .snappy(duration: 0.26 * slow) }

    /// Debug builds: `-browserSlow 6` runs every move six times slower, to
    /// look at frame by frame.
    static let slow: Double = {
        #if DEBUG
        let value = UserDefaults.standard.double(forKey: "browserSlow")
        return value > 0 ? value : 1
        #else
        return 1
        #endif
    }()
}

extension Browser: TabDelegate {
    /// Progress alone moves only the bar's line; anything else redraws
    /// what shows the tab.
    func tabDidChange(_ tab: Tab) {
        if tab === selected { progress = tab.isLoading ? tab.progress : nil }
        let state = "\(tab.title)|\(tab.url?.absoluteString ?? "")|\(tab.isLoading)|\(tab.persist)|\(tab.internalPage ?? "")|\(tab.index)"
        guard states[tab.id] != state else { return }
        states[tab.id] = state
        revision += 1
        saveTabs()
    }

    func tab(_ tab: Tab, didReplace old: WKWebView?) {
        revision += 1
    }

    func tab(_ tab: Tab, openInNewTab url: URL) {
        newTab(url, after: tab)
    }

    func tab(_ tab: Tab, didOpenPopup popup: Tab) {
        if let i = tabs.firstIndex(where: { $0 === tab }) { tabs.insert(popup, at: i + 1) } else { tabs.append(popup) }
        popup.delegate = self
        select(popup)
    }

    func tabWantsToClose(_ tab: Tab) { close(tab) }

    func tab(_ tab: Tab, allowCapture type: WKMediaCaptureType, for origin: String) async -> Bool {
        let what = switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        default: "camera and microphone"
        }
        return await Dialogs.confirm("\(origin) wants to use your \(what).", ok: "Allow", cancel: "Don't Allow")
    }

    /// Downloads go to Browser's folder in the Files app.
    func tab(_ tab: Tab, saveDownload name: String) async -> URL? {
        let folder = URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var file = folder.appending(path: name)
        let base = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        notice = "Downloading \(file.lastPathComponent)"
        return file
    }

    func tab(_ tab: Tab, runAlert message: String) async {
        _ = await Dialogs.confirm(message, ok: "OK", cancel: nil)
    }

    func tab(_ tab: Tab, runConfirm message: String) async -> Bool {
        await Dialogs.confirm(message, ok: "OK", cancel: "Cancel")
    }

    func tab(_ tab: Tab, runPrompt message: String, defaultText: String?) async -> String? {
        await Dialogs.prompt(message, defaultText: defaultText)
    }

    func tab(_ tab: Tab, chooseFiles multiple: Bool, directories: Bool) async -> [URL]? { nil }
}

/// A page's alert, confirm and prompt, and Browser's own questions.
@MainActor
enum Dialogs {
    static var top: UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    static func confirm(_ message: String, ok: String, cancel: String?, destructive: Bool = false) async -> Bool {
        await withCheckedContinuation { done in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            if let cancel { alert.addAction(UIAlertAction(title: cancel, style: .cancel) { _ in done.resume(returning: false) }) }
            alert.addAction(UIAlertAction(title: ok, style: destructive ? .destructive : .default) { _ in done.resume(returning: true) })
            guard let top else { done.resume(returning: false); return }
            top.present(alert, animated: true)
        }
    }

    static func prompt(_ message: String, defaultText: String?) async -> String? {
        await withCheckedContinuation { done in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in done.resume(returning: alert?.textFields?.first?.text ?? "") })
            guard let top else { done.resume(returning: nil); return }
            top.present(alert, animated: true)
        }
    }
}
