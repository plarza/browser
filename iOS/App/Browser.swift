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

    /// The selected tab's page sits on its card in the grid, so the card
    /// shows it; otherwise the page is on its way to or from it.
    var landed = false
    /// Pictures of pages, by tab and place in its back and forward list:
    /// each tab's current page for the grid and the tab stack, and the
    /// pages either side for swipes.
    private(set) var pictures: [PictureKey: UIImage] = [:]
    @ObservationIgnored private var recent: [PictureKey] = []
    @ObservationIgnored private(set) var stage: Stage!
    /// Where each card sits on screen, for the page to shrink into. Written
    /// during layout, so nothing redraws for it.
    @ObservationIgnored var cardFrames: [UUID: CGRect] = [:]
    @ObservationIgnored private var states: [UUID: String] = [:]
    @ObservationIgnored private var loading: Set<UUID> = []
    var gridShown: Bool { gridProgress >= 1 }

    struct PictureKey: Hashable {
        let tab: UUID
        let index: Int
    }

    init() {
        stage = Stage(browser: self)
    }

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

    func select(_ tab: Tab) {
        guard tabs.contains(where: { $0 === tab }), selected !== tab else { return }
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
        forgetPictures { $0.tab == tab.id }
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
        barCollapsed = false
        withAnimation(Motion.spring(velocity: velocity)) { gridProgress = 1 }
    }

    /// The selected card (or `tab`'s) grows back into the page.
    func showPage(_ tab: Tab? = nil, velocity: CGFloat = 0) {
        if let tab { select(tab) }
        withAnimation(Motion.spring(velocity: velocity)) { gridProgress = 0 }
    }

    // MARK: Pictures

    /// The picture of `tab`'s page at `index` in its back and forward
    /// list; by default, the page it's on.
    func picture(_ tab: Tab, at index: Int? = nil) -> UIImage? {
        pictures[PictureKey(tab: tab.id, index: index ?? tab.index)]
    }

    /// What the selected tab shows now, taken while nothing moves (once a
    /// page comes to rest or finishes loading) so nothing waits for it.
    func capture(_ tab: Tab) {
        guard tab === selected, tab.index >= 0, let image = stage.pages.render() else { return }
        // Kept a moment later: this can be asked for in the middle of
        // SwiftUI drawing, which mustn't change what it's drawing.
        let key = PictureKey(tab: tab.id, index: tab.index)
        DispatchQueue.main.async { self.keep(image, key) }
    }

    private func keep(_ image: UIImage, _ key: PictureKey) {
        guard tabs.contains(where: { $0.id == key.tab }) else { return }
        pictures[key] = image
        recent.removeAll { $0 == key }
        recent.append(key)
        // Each tab's current page stays; of the rest, the latest few.
        let current = Set(tabs.map { PictureKey(tab: $0.id, index: $0.index) })
        let others = recent.filter { !current.contains($0) }
        if others.count > 12 { forgetPictures(Set(others.prefix(others.count - 12)).contains) }
    }

    private func forgetPictures(_ matching: (PictureKey) -> Bool) {
        for key in pictures.keys where matching(key) { pictures[key] = nil }
        recent.removeAll(where: matching)
    }

    /// The address sheet up or down.
    func edit(_ target: Editing?) {
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
            let step = (target === previous ? 1 : -1) * (width + Pages.gap)
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                select(target)
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
        // Pages gone from the back and forward list take their pictures.
        let count = tab.entries.count
        if pictures.keys.contains(where: { $0.tab == tab.id && $0.index >= count }) {
            forgetPictures { $0.tab == tab.id && $0.index >= count }
        }
        // A page done loading has its picture taken once it's drawn.
        if tab.isLoading { loading.insert(tab.id) } else if loading.remove(tab.id) != nil, tab === selected {
            stage.pages.captureSoon()
        }
        revision += 1
        saveTabs()
    }

    func tab(_ tab: Tab, didReplace old: WKWebView?) {
        stage.pages.prepare(tab.webView)
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
