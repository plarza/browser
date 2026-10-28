import AppKit
import WebKit

@MainActor
public protocol TabDelegate: AnyObject {
    /// Title, address, loading or Persist changed.
    func tabDidChange(_ tab: Tab)
    /// The tab now shows a different web view: a wipe swapped it out.
    func tab(_ tab: Tab, didReplace old: WKWebView?)
    /// ⌘-click, middle-click, target=_blank: a new tab with a new identity.
    func tab(_ tab: Tab, openInNewTab url: URL)
    /// A `window.open` popup sharing this tab's jar.
    func tab(_ tab: Tab, didOpenPopup popup: Tab)
    /// The page called `window.close()`.
    func tabWantsToClose(_ tab: Tab)
    /// Camera or microphone; asked every time, never remembered.
    func tab(_ tab: Tab, allowCapture type: WKMediaCaptureType, for origin: String) async -> Bool
    /// Every download asks first.
    func tab(_ tab: Tab, allowDownload name: String, size: Int64?) async -> Bool
    func tab(_ tab: Tab, runAlert message: String) async
    func tab(_ tab: Tab, runConfirm message: String) async -> Bool
    func tab(_ tab: Tab, runPrompt message: String, defaultText: String?) async -> String?
    func tab(_ tab: Tab, chooseFiles multiple: Bool, directories: Bool) async -> [URL]?
}

/// A tab is a sequence of identities. Every navigation, reload, back and
/// forward included, throws the current identity away and loads into a
/// new web view with a new one — unless the tab is on Persist, or the page
/// is on a whitelisted domain, whose jar stays.
@MainActor
public final class Tab: NSObject {
    public let id = UUID()
    public weak var delegate: TabDelegate?

    public private(set) var webView: WKWebView
    public private(set) var identity: Identity

    /// Keep this tab's identity through reloads and navigation. It still
    /// dies with the tab.
    public var persist = false {
        didSet { if persist != oldValue { delegate?.tabDidChange(self) } }
    }

    public private(set) var title = ""
    public private(set) var url: URL?
    public private(set) var isLoading = false
    public private(set) var progress = 0.0

    /// Core's own back and forward: WebKit's list belongs to one web view,
    /// and a wipe throws the web view away.
    public private(set) var entries: [URL] = []
    public private(set) var index = -1
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    /// Popups this tab opened; they share its jar and close with it.
    public private(set) var popups: [Tab] = []
    public private(set) weak var opener: Tab?

    /// The fresh identity this tab owns, kept while Persist is on. A
    /// whitelisted page borrows its domain's jar instead.
    private var own: Identity

    private var observations: [NSKeyValueObservation] = []
    /// The next main-frame decision is a load Core started itself.
    private var expecting = false
    /// Between a provisional start and its commit or failure: a decision
    /// here is a server redirect, which stays in the same identity.
    private var provisional = false
    /// The address typed as `http://` that was tried as `https://`.
    private var upgradedFrom: URL?
    /// The one load allowed over plain HTTP, after the interstitial.
    private var httpAllowed: URL?
    private let interstitialToken = UUID().uuidString.lowercased()
    private var pendingDirection: Direction = .new
    private var lastCrash: Date?

    private enum Direction { case new, back, forward, reload }

    public init(delegate: TabDelegate?) {
        self.delegate = delegate
        let identity = Identity.fresh()
        own = identity
        self.identity = identity
        webView = Tab.makeWebView(Engine.configuration(for: identity, content: Blocker.shared.controller()))
        super.init()
        attach()
    }

    /// A popup: WebKit hands over the configuration it must be made with,
    /// which carries the opener's data store.
    private init(popupOf opener: Tab, configuration: WKWebViewConfiguration) {
        delegate = opener.delegate
        self.opener = opener
        own = opener.identity
        identity = opener.identity
        persist = true
        webView = Tab.makeWebView(configuration)
        super.init()
        attach()
    }

    private static func makeWebView(_ configuration: WKWebViewConfiguration) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = true
        view.isInspectable = false
        return view
    }

    private func attach() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, self.internalPage == nil else { return }
                    self.update(.title) { $0.title = view.title ?? "" }
                    if let url = self.url, url.scheme == "https" || url.scheme == "http" {
                        History.shared.setTitle(self.title, for: url)
                    }
                }
            },
            webView.observe(\.url) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = view.url, url.scheme == "http" || url.scheme == "https" else { return }
                    self.update(.URL) { $0.url = url }
                }
            },
            webView.observe(\.isLoading) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.update(.loading) { $0.isLoading = view.isLoading } }
            },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.update { $0.progress = view.estimatedProgress } }
            },
        ]
    }

    private func update(_ properties: WKWebExtension.TabChangedProperties = [], _ change: (Tab) -> Void) {
        change(self)
        delegate?.tabDidChange(self)
        if !properties.isEmpty { Extensions.shared.didChange(self, properties) }
    }

    // MARK: Navigating

    public func load(_ url: URL) {
        pending = nil
        navigate(URLRequest(url: url), direction: .new)
    }

    /// A tab restored at launch: its address is known, nothing is loaded
    /// (no process, no request) until it is first shown.
    public private(set) var pending: URL?

    public func restore(_ url: URL) {
        pending = url
        self.url = url
        title = url.host ?? ""
    }

    /// Loads a restored tab's address, if it has one waiting.
    public func wake() {
        if let pending { load(pending) }
    }

    public func reload() {
        guard index >= 0 else { return }
        navigate(URLRequest(url: entries[index]), direction: .reload)
    }

    public func goBack() {
        guard canGoBack else { return }
        navigate(URLRequest(url: entries[index - 1]), direction: .back)
    }

    public func goForward() {
        guard canGoForward else { return }
        navigate(URLRequest(url: entries[index + 1]), direction: .forward)
    }

    public func stop() { webView.stopLoading() }

    public func close() {
        for popup in popups { popup.close() }
        popups = []
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        opener?.popups.removeAll { $0 === self }
    }

    /// The identity a load to `host` belongs in.
    private func identity(for host: String?) -> Identity {
        if let domain = Whitelist.domain(for: host) { return .whitelisted(domain) }
        if persist { return own }
        own = .fresh()
        return own
    }

    /// One of Core's own pages, shown by the shell in place of the web view.
    public private(set) var internalPage: String?

    private func showInternal(_ page: String, direction: Direction) {
        // An empty web view underneath: nothing of the last page stays.
        replaceWebView(with: .fresh())
        internalPage = page
        pendingDirection = direction
        let address = InternalPage.address(page)
        recordEntry(address)
        update(.URL) { $0.url = address }
        update(.title) { $0.title = page.capitalized }
    }

    private func navigate(_ request: URLRequest, direction: Direction) {
        guard var url = request.url else { return }
        if let page = InternalPage.page(url) {
            showInternal(page, direction: direction)
            return
        }
        internalPage = nil
        url = CleanLink.clean(url)
        upgradedFrom = nil
        if url.scheme?.lowercased() == "http", url != httpAllowed {
            upgradedFrom = url
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.scheme = "https"
            if parts?.port == 80 { parts?.port = nil }
            url = parts?.url ?? url
        }
        var request = request
        request.url = url

        // A wiped load gets a new identity, so it is never the current one.
        let target = identity(for: url.host)
        if target !== identity { replaceWebView(with: target) }
        pendingDirection = direction
        expecting = true
        webView.load(request)
    }

    private func replaceWebView(with target: Identity) {
        identity = target
        replaceWebView(with: Engine.configuration(for: target, content: Blocker.shared.controller()))
    }

    private func replaceWebView(with configuration: WKWebViewConfiguration) {
        internalPage = nil
        let old = webView
        observations = []
        old.stopLoading()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        // A popup's jar is its opener's; once the opener moves on, the
        // popup has nothing to share and closes.
        for popup in popups { popup.close(); delegate?.tabWantsToClose(popup) }
        popups = []
        webView = Tab.makeWebView(configuration)
        attach()
        delegate?.tab(self, didReplace: old)
        old.removeFromSuperview()
    }

    private func record(_ url: URL) {
        recordEntry(url)
        History.shared.add(url)
    }

    private func recordEntry(_ url: URL) {
        switch pendingDirection {
        case .new:
            if index >= 0, entries[index] == url { break }
            entries.removeSubrange((index + 1)...)
            entries.append(url)
            index = entries.count - 1
        case .back: index = max(0, index - 1); entries[index] = url
        case .forward: index = min(entries.count - 1, index + 1); entries[index] = url
        case .reload: if index >= 0 { entries[index] = url }
        }
        pendingDirection = .new
        delegate?.tabDidChange(self)
    }

    /// What the main frame is about to do, decided before WebKit does it.
    private func decide(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""

        if scheme == "core-allow-http", url.absoluteString.hasPrefix("core-allow-http:\(interstitialToken)?"),
           let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "u" })?.value.flatMap(URL.init(string:)) {
            httpAllowed = target
            navigate(URLRequest(url: target), direction: .reload)
            return .cancel
        }
        if scheme == "about" || scheme == "blob" || scheme == "data" { return .allow }
        if scheme == "mailto" || scheme == "tel" || scheme == "facetime" {
            if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            return .cancel
        }
        guard scheme == "http" || scheme == "https" else { return .cancel }

        if action.navigationType == .linkActivated,
           action.modifierFlags.contains(.command) || action.buttonNumber == 2 {
            delegate?.tab(self, openInNewTab: url)
            return .cancel
        }
        if expecting { expecting = false; return .allow }
        if provisional { return .allow } // a redirect: same load, same identity
        if let current = webView.url, Tab.sameDocument(current, url), action.navigationType != .reload {
            return .allow
        }
        switch action.navigationType {
        case .backForward:
            if canGoBack, entries[index - 1] == url { goBack() } else { goForward() }
        case .reload:
            reload()
        default:
            // A navigation the page or the person started: in place when
            // nothing would change identity, otherwise anew.
            let staysPut: Bool
            if let domain = Whitelist.domain(for: url.host) {
                staysPut = identity.kind == .whitelisted(domain)
            } else {
                staysPut = persist && identity === own
            }
            if staysPut, scheme == "https", CleanLink.clean(url) == url {
                pendingDirection = .new
                return .allow
            }
            navigate(action.request, direction: .new)
        }
        return .cancel
    }

    static func sameDocument(_ a: URL, _ b: URL) -> Bool {
        guard b.fragment != nil else { return false }
        var x = URLComponents(url: a, resolvingAgainstBaseURL: false)
        var y = URLComponents(url: b, resolvingAgainstBaseURL: false)
        x?.fragment = nil
        y?.fragment = nil
        return x?.url == y?.url
    }

    private func showInterstitial(for url: URL) {
        var parts = URLComponents()
        parts.scheme = "core-allow-http"
        parts.path = interstitialToken
        parts.queryItems = [URLQueryItem(name: "u", value: url.absoluteString)]
        let link = parts.url?.absoluteString ?? ""
        let host = url.host ?? url.absoluteString
        let page = """
        <!doctype html><meta charset=utf-8><title>Not secure</title>
        <style>
        :root{color-scheme:light dark;font:15px -apple-system,system-ui}
        body{max-width:32rem;margin:18vh auto;padding:0 1.5rem;line-height:1.5}
        h1{font-size:1.25rem;font-weight:600}
        a.button{display:inline-block;margin-top:1rem;padding:.45rem .9rem;border-radius:.5rem;border:1px solid #8886;color:inherit;text-decoration:none}
        code{font:13px ui-monospace,monospace}
        </style>
        <h1>\(Tab.escape(host)) has no secure connection</h1>
        <p>Core tried <code>https://</code> and it did not work. Over plain HTTP anyone between you and the site can read and change the page.</p>
        <a class=button href="\(Tab.escape(link))">Continue over HTTP, this once</a>
        """
        webView.loadHTMLString(page, baseURL: nil)
        update { $0.url = url }
    }

    private func showCrashed() {
        let host = Tab.escape(url?.host ?? "This page")
        webView.loadHTMLString("""
        <!doctype html><meta charset=utf-8><title>Crashed</title>
        <style>:root{color-scheme:light dark;font:15px -apple-system,system-ui}
        body{max-width:32rem;margin:18vh auto;padding:0 1.5rem;line-height:1.5}
        h1{font-size:1.25rem;font-weight:600}</style>
        <h1>\(host) keeps crashing</h1>
        <p>Core stopped reloading it. Press ⌘R to try again.</p>
        """, baseURL: nil)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension Tab: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        Engine.harden(preferences, seed: identity.seed)
        if action.shouldPerformDownload { return (.download, preferences) }
        guard action.targetFrame?.isMainFrame ?? false else { return (.allow, preferences) }
        return (decide(action), preferences)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !response.canShowMIMEType { return .download }
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        provisional = true
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        provisional = false
        httpAllowed = nil
        if let url = webView.url, url.scheme == "http" || url.scheme == "https" { record(url) }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        provisional = false
        let code = (error as NSError).code
        if let original = upgradedFrom, (error as NSError).domain == NSURLErrorDomain, code != NSURLErrorCancelled {
            upgradedFrom = nil
            showInterstitial(for: original)
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Favicons.shared.load(for: self)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        provisional = false
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = Downloads.shared.adopt(download, for: self)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = Downloads.shared.adopt(download, for: self)
    }

    /// A crashed page reloads once. If it crashes again soon after, it
    /// stays down and says so, rather than reloading forever.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        defer { lastCrash = now }
        if let lastCrash, now.timeIntervalSince(lastCrash) < 20 {
            showCrashed()
            return
        }
        reload()
    }
}

extension Tab: WKUIDelegate {
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A sized window is a popup that expects its opener (sign-in,
        // 3-D Secure); anything else is a new tab, which starts fresh.
        let sized = windowFeatures.width != nil || windowFeatures.height != nil
        guard sized else {
            if let url = action.request.url { delegate?.tab(self, openInNewTab: url) }
            return nil
        }
        let popup = Tab(popupOf: self, configuration: configuration)
        popups.append(popup)
        delegate?.tab(self, didOpenPopup: popup)
        return popup.webView
    }

    public func webViewDidClose(_ webView: WKWebView) {
        delegate?.tabWantsToClose(self)
    }

    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let who = origin.port == 0 ? "\(origin.protocol)://\(origin.host)" : "\(origin.protocol)://\(origin.host):\(origin.port)"
        guard let delegate else { return .deny }
        return await delegate.tab(self, allowCapture: type, for: who) ? .grant : .deny
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        await delegate?.tab(self, runAlert: message)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await delegate?.tab(self, runConfirm: message) ?? false
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await delegate?.tab(self, runPrompt: prompt, defaultText: defaultText)
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await delegate?.tab(self, chooseFiles: parameters.allowsMultipleSelection, directories: parameters.allowsDirectories)
    }
}
