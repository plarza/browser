#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation
import WebKit

/// A tab is a sequence of identities. Every navigation to another site, and
/// every reload or typed address, throws the current identity away and
/// loads into a new web view with a new one, unless the tab is on Persist,
/// or the page is on a whitelisted domain, whose jar stays. Links, back and
/// forward within one site keep the identity, and the web view with it.
///
/// What a tab shows is observable; the shell reads it and keeps up.
@MainActor @Observable
public final class Tab: NSObject {
    public let id = UUID()

    public internal(set) var title = ""
    public internal(set) var url: URL?
    public internal(set) var isLoading = false
    public internal(set) var progress = 0.0
    /// One of Browser's own pages, shown by the shell in place of the web view.
    public internal(set) var page: InternalPage?
    /// A tab restored at launch: its address is known, nothing is loaded
    /// (no process, no request) until it is first shown.
    public internal(set) var pending: URL?
    /// Browser's own back and forward list.
    public internal(set) var backForward = BackForwardList()
    /// Find on page's answer: how many matches, and which is current.
    public internal(set) var found: Found?

    /// The page's web view. A wipe replaces it; a link within the site keeps it.
    public internal(set) var webView: WKWebView
    /// What the shell shows: the web view, and across a wipe the page
    /// before it, until the next one draws.
    @ObservationIgnored public let view = PageView()
    public internal(set) var identity: Identity

    /// Popups this tab opened; they share its jar and close with it.
    public internal(set) var popups: [Tab] = []
    @ObservationIgnored public private(set) weak var opener: Tab?
    @ObservationIgnored weak var browser: Browser?

    /// The fresh identity this tab owns, kept while Persist is on. A
    /// whitelisted page borrows its domain's jar instead.
    var own: Identity
    private var persisting = false
    @ObservationIgnored var loading = Loading()
    @ObservationIgnored let finder = FindReporter()
    /// Proves a click on a notice's button came from the notice.
    @ObservationIgnored let noticeToken = UUID().uuidString.lowercased()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Jars given up by turning Persist off, deleted once nothing uses them.
    @ObservationIgnored private var retired: [UUID] = []
    @ObservationIgnored private(set) var isClosed = false

    init(browser: Browser?) {
        self.browser = browser
        let identity = Identity.fresh()
        own = identity
        self.identity = identity
        webView = Tab.makeWebView(Engine.configuration(for: identity))
        super.init()
        attach(replacing: nil, handover: false)
    }

    /// A popup: WebKit hands over the configuration it must be made with,
    /// which carries the opener's data store.
    init(popupOf opener: Tab, configuration: WKWebViewConfiguration) {
        browser = opener.browser
        self.opener = opener
        own = opener.identity
        identity = opener.identity
        persisting = true
        webView = Tab.makeWebView(configuration)
        super.init()
        attach(replacing: nil, handover: false)
    }

    /// The tab showing in `webView`, if it still is one's.
    static func showing(_ webView: WKWebView?) -> Tab? {
        guard let webView, let tab = webView.navigationDelegate as? Tab, tab.webView === webView else { return nil }
        return tab
    }

    // MARK: What it shows

    public var canGoBack: Bool { backForward.canGoBack }
    public var canGoForward: Bool { backForward.canGoForward }
    public var isPopup: Bool { opener != nil }

    /// A tab with nowhere to go: it shows the new tab page.
    public var isBlank: Bool { url == nil && pending == nil && !isLoading }

    /// What to call the tab when its page has no title.
    public var name: String { title.isEmpty ? url?.host ?? "" : title }

    // MARK: Persist

    /// Keep this tab's identity through reloads and navigation. It still
    /// dies with the tab.
    public var persist: Bool {
        get { persisting }
        set {
            guard newValue != persisting else { return }
            persisting = newValue
            guard !isPopup else { return }
            if newValue {
                // The next load moves into the kept jar, bringing what the
                // tab has so far (see `carry`).
                if own.kind == .fresh { own = .kept() }
            } else if let id = own.keptID {
                retired.append(id)
                own = .fresh()
                dropRetired()
            }
        }
    }

    /// The tab's jar on disk while Persist is on, so it survives a relaunch.
    public var keptIdentity: UUID? { own.keptID }

    func dropRetired() {
        let unused = retired.filter { identity.kind != .kept($0) }
        retired.removeAll(where: unused.contains)
        for id in unused { Task { await Identity.forget(kept: id) } }
    }

    // MARK: Going places

    /// `kind`: how much the visit counts in History.
    public func load(_ url: URL, as kind: History.Kind = .link) {
        pending = nil
        navigate(URLRequest(url: url), as: .new)
        loading.visit = kind
    }

    public func reload() {
        guard let url = backForward.current else { return }
        navigate(URLRequest(url: url), as: .reload)
    }

    public func goBack() {
        guard let url = backForward.back else { return }
        navigate(URLRequest(url: url), as: .back, sameSite: true)
    }

    public func goForward() {
        guard let url = backForward.forward else { return }
        navigate(URLRequest(url: url), as: .forward, sameSite: true)
    }

    public func stop() { webView.stopLoading() }

    /// Restored at launch, asleep until first shown. `kept`: a Persist
    /// tab's jar from the last session.
    func restore(_ url: URL, kept: UUID?) {
        if let kept {
            own = .kept(kept)
            persisting = true
        }
        pending = url
        self.url = url
        // History's title, so nothing is kept that History doesn't already
        // keep; the host if the page isn't in History.
        title = History.shared.title(for: url) ?? url.host ?? ""
    }

    /// Loads a restored tab's address, if it has one waiting.
    public func wake() {
        if let pending { load(pending, as: .reload) }
    }

    /// Closing destroys the session: the web view goes, and a Persist tab's
    /// jar is deleted from the disk.
    func close() {
        isClosed = true
        if let id = own.keptID, !isPopup { retired.append(id) }
        identity = .fresh()
        dropRetired()
        for popup in popups { popup.close() }
        popups = []
        detach(webView)
        view.clear()
        view.removeFromSuperview()
        opener?.popups.removeAll { $0 === self }
        Userscripts.shared.tabClosed(self)
    }

    // MARK: Web views

    private static func makeWebView(_ configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        #if os(macOS)
        webView.allowsMagnification = true
        #endif
        webView.isInspectable = false
        return webView
    }

    /// A new web view for `target`, the old one let go.
    func replaceWebView(with target: Identity, handover: Bool = true) {
        identity = target
        replaceWebView(with: Engine.configuration(for: target), handover: handover)
        dropRetired()
    }

    /// `handover`: the old page stays up until the new one draws.
    func replaceWebView(with configuration: WKWebViewConfiguration, handover: Bool = true) {
        page = nil
        let old = webView
        detach(old, keepOnScreen: true)
        // A popup's jar is its opener's; once the opener moves on, the
        // popup has nothing to share and closes.
        for popup in popups {
            if let browser { browser.close(popup) } else { popup.close() }
        }
        popups = []
        webView = Tab.makeWebView(configuration)
        attach(replacing: old, handover: handover)
    }

    /// Takes hold of `webView`: its delegates, what it reports, its place
    /// in `view`. The shell hears of it before it loads anything.
    private func attach(replacing old: WKWebView?, handover: Bool) {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        Tab.observeFirstDraw(webView)
        observations = [
            watch(\.title) { tab, webView in
                guard tab.page == nil else { return }
                tab.title = webView.title ?? ""
                Extensions.shared.didChange(tab, .title)
                if let url = tab.url, url.isWeb { History.shared.setTitle(tab.title, for: url) }
            },
            watch(\.url) { tab, webView in
                guard let url = webView.url, url.isWeb || url.isFileURL || Extensions.shared.context(for: url) != nil else { return }
                tab.show(url)
            },
            watch(\.isLoading) { tab, webView in
                tab.isLoading = webView.isLoading
                Extensions.shared.didChange(tab, .loading)
            },
            watch(\.estimatedProgress) { tab, webView in
                tab.progress = webView.estimatedProgress
            },
        ]
        view.show(webView, replacing: handover ? old : nil)
        browser?.shell?.tab(self, didReplace: old)
    }

    private func watch<Value>(_ keyPath: KeyPath<WKWebView, Value>, _ changed: @escaping @MainActor (Tab, WKWebView) -> Void) -> NSKeyValueObservation {
        webView.observe(keyPath) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                changed(self, self.webView)
            }
        }
    }

    /// Lets go of a web view: nothing it does reaches this tab any more.
    /// One being replaced stays on screen until its successor draws.
    private func detach(_ webView: WKWebView, keepOnScreen: Bool = false) {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if !keepOnScreen { webView.removeFromSuperview() }
    }

    /// The address the tab shows, told to extensions too.
    func show(_ url: URL?) {
        self.url = url
        Extensions.shared.didChange(self, .URL)
    }

    func show(title: String) {
        self.title = title
        Extensions.shared.didChange(self, .title)
    }
}
