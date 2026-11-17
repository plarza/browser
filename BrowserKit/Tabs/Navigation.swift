#if os(macOS)
import AppKit
#else
import UIKit
#endif
import WebKit

extension Tab {
    /// What a tab keeps about the load under way.
    struct Loading {
        /// The next main-frame decision is a load Browser started itself.
        var expected = false
        /// Between a provisional start and its commit or failure: a decision
        /// here is a server redirect, which stays in the same identity.
        var provisional = false
        /// How the load changes the back and forward list once it commits.
        var move = BackForwardList.Move.new
        /// How the load under way counts in History, and how the page showing did.
        var visit = History.Kind.link
        var shown = History.Kind.link
        /// The address typed as `http://` that was tried as `https://`.
        var upgradedFrom: URL?
        /// The one load allowed over plain HTTP, after the interstitial.
        var httpAllowed: URL?
        /// A carried page's storage, waiting to be written into the kept jar.
        var carrying: WKUserScript?
        var lastCrash: Date?
    }

    // MARK: Where a load goes

    /// `sameSite`: a link, back or forward, which keeps the identity if it
    /// stays on the site showing; a reload or a typed address never does.
    func navigate(_ request: URLRequest, as move: BackForwardList.Move, sameSite: Bool = false) {
        guard var url = request.url else { return }
        loading.visit = move == .reload ? .reload : .link
        if url == BackForwardList.blank { return showBlank(as: move) }
        if move == .new, backForward.isEmpty, self.url == nil, pending == nil { backForward.beginBlank() }
        if let page = InternalPage(url) { return show(page, as: move) }
        page = nil

        if let configuration = Extensions.shared.context(for: url)?.webViewConfiguration {
            replaceWebView(with: configuration)
            loading.move = move
            show(url)
            webView.load(request)
            return
        }
        if url.isFileURL {
            enter(identity(for: url))
            loading.move = move
            loading.expected = true
            // Images, scripts and styles anywhere on the disk, `../` ones
            // included; WebKit still keeps a file's page from reading other files.
            webView.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/"))
            return
        }

        url = CleanLink.clean(url)
        loading.upgradedFrom = nil
        if url.scheme?.lowercased() == "http", url != loading.httpAllowed, !Site.isLoopback(url.host) {
            loading.upgradedFrom = url
            url = Tab.secure(url)
        }
        var request = request
        request.url = url

        // A wiped load gets a new identity, so it is never the current one.
        let target = identity(for: url, sameSite: sameSite)
        if target !== identity, target.keptID != nil, identity.kind == .fresh {
            // Persist was just turned on: the tab's cookies and the page's
            // storage go into its kept jar before the load.
            let from = identity.store, page = webView
            Task {
                let restore = await Tab.carry(from: from, page: page, to: target.store)
                guard own === target, !isClosed else { return }
                replaceWebView(with: target)
                if let restore {
                    webView.configuration.userContentController.addUserScript(restore)
                    loading.carrying = restore
                }
                start(request, as: move)
            }
            return
        }
        enter(target)
        start(request, as: move)
    }

    private func start(_ request: URLRequest, as move: BackForwardList.Move) {
        loading.move = move
        loading.expected = true
        webView.load(request)
    }

    /// The web view for `target`: the one showing if it is already in
    /// that identity, otherwise a new one.
    private func enter(_ target: Identity) {
        if target !== identity || webView.configuration.websiteDataStore !== target.store { replaceWebView(with: target) }
    }

    /// The identity a load to `url` belongs in. With `sameSite`, a page on
    /// the site showing keeps the tab's own identity.
    private func identity(for url: URL, sameSite: Bool = false) -> Identity {
        if let domain = Whitelist.domain(for: url.host) { return .whitelisted(domain) }
        if persist { return own }
        if sameSite, identity === own, keepsIdentity(to: url) { return own }
        own = .fresh()
        return own
    }

    /// The page showing is on `url`'s site, in this web view.
    private func keepsIdentity(to url: URL) -> Bool {
        page == nil && webView.configuration.websiteDataStore === identity.store && Site.same(webView.url, url)
    }

    private static func secure(_ url: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = "https"
        if parts?.port == 80 { parts?.port = nil }
        return parts?.url ?? url
    }

    /// Cookies from one jar into another, and a script that puts the page's
    /// local and session storage back for the same origin.
    static func carry(from: WKWebsiteDataStore, page: WKWebView, to: WKWebsiteDataStore) async -> WKUserScript? {
        // The page first: reading `document.cookie` waits for the cookies
        // the page has just set to reach the jar, which they do on their own
        // time, so the copy below has them.
        let read = "document.cookie, JSON.stringify({origin: location.origin, local: Object.entries(localStorage), session: Object.entries(sessionStorage)})"
        let json = page.url?.isWeb == true ? try? await page.evaluateJavaScript(read, in: nil, contentWorld: .defaultClient) as? String : nil
        for cookie in await from.httpCookieStore.allCookies() { await to.httpCookieStore.setCookie(cookie) }
        guard let json else { return nil }
        let source = """
        (() => { const s = \(json); if (location.origin !== s.origin) return;
          for (const [k, v] of s.local) if (localStorage.getItem(k) === null) localStorage.setItem(k, v);
          for (const [k, v] of s.session) if (sessionStorage.getItem(k) === null) sessionStorage.setItem(k, v); })()
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)
    }

    // MARK: Pages that aren't web pages

    /// The new tab page: an empty web view underneath, nothing of the last
    /// page left.
    private func showBlank(as move: BackForwardList.Move) {
        replaceWebView(with: .fresh(), handover: false)
        loading.move = .new
        backForward.record(BackForwardList.blank, as: move)
        show(nil)
        show(title: "")
    }

    private func show(_ page: InternalPage, as move: BackForwardList.Move) {
        replaceWebView(with: .fresh(), handover: false)
        loading.move = .new
        self.page = page
        backForward.record(page.url, as: move)
        show(page.url)
        show(title: page.title)
    }

    // MARK: What the page may do

    /// What the main frame is about to do, decided before WebKit does it.
    private func decide(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""

        if let allowed = Notice.httpAllowed(by: url, token: noticeToken) {
            loading.httpAllowed = allowed
            navigate(URLRequest(url: allowed), as: .reload)
            return .cancel
        }
        if ["about", "blob", "data"].contains(scheme) || Extensions.shared.context(for: url) != nil { return .allow }
        if ["mailto", "tel", "facetime"].contains(scheme) {
            if action.navigationType == .linkActivated { Tab.openElsewhere(url) }
            return .cancel
        }
        // A file only from Browser itself or another file: never from a web page.
        let local = scheme == "file" && (loading.expected || webView.url?.isFileURL == true)
        guard scheme == "http" || scheme == "https" || local else { return .cancel }

        if action.navigationType == .linkActivated, Tab.wantsNewTab(action) {
            browser?.open(url, from: self)
            return .cancel
        }
        if loading.expected { loading.expected = false; return .allow }
        if loading.provisional { return .allow } // a redirect: same load, same identity
        if let current = webView.url, Tab.sameDocument(current, url), action.navigationType != .reload { return .allow }

        switch action.navigationType {
        case .backForward:
            if backForward.back == url { goBack() } else { goForward() }
        case .reload:
            reload()
        default:
            // A navigation the page or the person started: in place when
            // nothing would change identity, otherwise anew.
            let staysPut: Bool
            if let domain = Whitelist.domain(for: url.host) {
                staysPut = identity.kind == .whitelisted(domain)
            } else {
                staysPut = identity === own && (persist || keepsIdentity(to: url))
            }
            let move: BackForwardList.Move = Tab.isUserInitiated(action) || action.navigationType != .other ? .new : .replace
            let asIs = scheme == "https" || Site.isLoopback(url.host)
            if staysPut, webView.configuration.websiteDataStore === identity.store, asIs, CleanLink.clean(url) == url {
                loading.move = move
                return .allow
            }
            navigate(action.request, as: move, sameSite: true)
        }
        return .cancel
    }

    private static func openElsewhere(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// ⌘-click or middle-click: the link goes to a new tab.
    private static func wantsNewTab(_ action: WKNavigationAction) -> Bool {
        #if os(macOS)
        action.modifierFlags.contains(.command) || action.buttonNumber == 2
        #else
        action.modifierFlags.contains(.command)
        #endif
    }

    private static func isUserInitiated(_ action: WKNavigationAction) -> Bool {
        action.value(forKey: "_isUserInitiated") as? Bool ?? true
    }

    private static func sameDocument(_ a: URL, _ b: URL) -> Bool {
        let page = { (url: URL) in url.absoluteString.prefix { $0 != "#" } }
        return b.fragment != nil && page(a) == page(b)
    }

    // MARK: What happened

    /// The load committed: its page is the one showing now.
    private func record(_ url: URL) {
        if url.isWeb {
            // A page reached by a link that sent itself on counts low, as a reload does.
            if loading.move == .replace, loading.shown == .link, let before = backForward.current, before != url, before.isWeb {
                History.shared.redirected(from: before)
            }
            History.shared.add(url, as: loading.visit)
            loading.shown = loading.visit
            loading.visit = .link
        }
        backForward.record(url, as: loading.move)
        loading.move = .new
    }

    private static let firstVisuallyNonEmptyLayout: UInt = 1 << 1

    /// Asks WebKit to say when a page first draws something (see
    /// `renderingProgressDidChange`).
    static func observeFirstDraw(_ webView: WKWebView) {
        let set = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        guard webView.responds(to: set) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(webView.method(for: set), to: Set.self)(webView, set, firstVisuallyNonEmptyLayout)
    }
}

extension Tab: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        Engine.harden(preferences)
        if action.shouldPerformDownload { return (.download, preferences) }
        let isMainFrame = action.targetFrame?.isMainFrame
        let controller = webView.configuration.userContentController
        Scriptlets.shared.prepare(controller, for: action.request.url)
        Userscripts.shared.prepare(controller, for: action.request.url, mainFrame: isMainFrame ?? true)
        guard isMainFrame ?? false else { return (.allow, preferences) }
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
        loading.provisional = true
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        loading.provisional = false
        loading.httpAllowed = nil
        view.committed()
        Userscripts.shared.pageChanged(webView)
        guard let url = webView.url else { return }
        if url.isWeb || url.isFileURL || Extensions.shared.context(for: url) != nil { record(url) }
    }

    /// A page that changes its address without loading (pushState, as
    /// GitHub and most apps do, or an anchor): WebKit's private delegate
    /// call, since nothing commits.
    @objc(_webView:navigation:didSameDocumentNavigation:)
    func webView(_ webView: WKWebView, navigation: WKNavigation?, didSameDocumentNavigation type: Int) {
        guard webView === self.webView, let url = webView.url, url.isWeb || url.isFileURL,
              let change = BackForwardList.InPage(rawValue: type) else { return }
        if backForward.changedInPage(to: url, by: change) { History.shared.add(url, as: .link) }
    }

    /// The new page's first layout with something in it: WebKit's private
    /// call, the moment it stops showing the last page itself.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        if webView === self.webView, events & Tab.firstVisuallyNonEmptyLayout != 0 { view.drew() }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading.provisional = false
        let error = error as NSError
        if let original = loading.upgradedFrom, error.domain == NSURLErrorDomain, error.code != NSURLErrorCancelled {
            // No HTTPS there: offer the one load over HTTP.
            loading.upgradedFrom = nil
            webView.loadHTMLString(Notice.notSecure(original, token: noticeToken), baseURL: nil)
            url = original
        } else {
            view.drew()
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        view.drew()
        Favicons.shared.load(for: self)
        if let restore = loading.carrying {
            // Carried storage goes in once; a site that later clears it stays cleared.
            loading.carrying = nil
            webView.configuration.userContentController.remove(restore)
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading.provisional = false
        view.drew()
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = Downloads.shared.adopt(download, for: self)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = Downloads.shared.adopt(download, for: self)
    }

    /// Download Image and Download Linked File from the page's context menu:
    /// WebKit's private call, since no navigation becomes these downloads.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreate download: WKDownload) {
        download.delegate = Downloads.shared.adopt(download, for: self)
    }

    /// A crashed page reloads once. If it crashes again soon after, it
    /// stays down and says so, rather than reloading forever.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        defer { loading.lastCrash = now }
        if let last = loading.lastCrash, now.timeIntervalSince(last) < 20 {
            webView.loadHTMLString(Notice.crashed(url), baseURL: nil)
        } else {
            reload()
        }
    }
}
