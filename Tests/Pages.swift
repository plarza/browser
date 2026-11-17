#if DEBUG
import AppKit
import BrowserKit
import WebKit

/// Loading pages in tabs and running script in them.
extension SelfTest {
    /// What a script gave back, carried from WebKit's answer to whoever
    /// asked. Both ends are on the main actor.
    private struct Answer: @unchecked Sendable {
        let value: Any?
    }

    /// One answer for one question: WebKit's, or none after five seconds.
    @MainActor
    private final class Asked {
        private var waiting: CheckedContinuation<Answer, Never>?
        init(_ waiting: CheckedContinuation<Answer, Never>) { self.waiting = waiting }

        func answer(_ value: Any?) {
            waiting?.resume(returning: Answer(value: value))
            waiting = nil
        }
    }

    /// Script in the tab's page, answered within five seconds or not at all:
    /// WebKit can leave a call unanswered (a web view that never loaded).
    /// With `awaiting`, `source` is an expression whose promise is awaited.
    func js(_ tab: Tab, _ source: String, in world: WKContentWorld = .defaultClient, awaiting: Bool = false) async -> Any? {
        let webView = tab.webView
        return await withCheckedContinuation { (waiting: CheckedContinuation<Answer, Never>) in
            let asked = Asked(waiting)
            if awaiting {
                webView.callAsyncJavaScript("return await (\(source))", arguments: [:], in: nil, in: world) { asked.answer(try? $0.get()) }
            } else {
                webView.evaluateJavaScript(source, in: nil, in: world) { asked.answer(try? $0.get()) }
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                asked.answer(nil)
            }
        }.value
    }

    /// Script the page runs for itself, without waiting for what it gives.
    func run(_ tab: Tab, _ source: String) {
        tab.webView.evaluateJavaScript(source, in: nil, in: .page) { _ in }
    }

    /// A new tab in front, showing `url`.
    func open(_ url: URL) async -> Tab {
        let tab = browser.newTab(url)
        await arrive(tab, at: url)
        await shown()
        return tab
    }

    /// Does `action`, then waits for the tab to have finished loading `url`
    /// as a new document: a mark left in the old one, in a world the page
    /// can't see, is gone.
    func go(_ tab: Tab, _ url: URL, _ action: () -> Void) async {
        // A web view that never loaded has no document to mark, and any it
        // gets is new.
        if tab.webView.url != nil { _ = await js(tab, "window.__selfTest = true") }
        action()
        await arrive(tab, at: url)
    }

    private func arrive(_ tab: Tab, at url: URL) async {
        var page: String?
        let arrived = await until("\(url.absoluteString) to load") {
            guard !tab.isLoading, tab.url == url else { return false }
            page = await js(tab, "(window.__selfTest ? 'the old document, ' : '') + document.readyState + ' ' + location.href") as? String
            return page == "complete \(url.absoluteString)"
        }
        if !arrived {
            check("\(url.absoluteString) loads", false, "url=\(tab.url?.absoluteString ?? "nil") loading=\(tab.isLoading) page=\(page ?? "no answer")")
        }
    }

    /// Clicks a link to `url` in the page.
    func follow(_ tab: Tab, _ url: URL) {
        run(tab, "const a = document.createElement('a'); a.href = '\(url.absoluteString)'; document.body.append(a); a.click()")
    }

    /// A cookie and a localStorage item, for telling one identity from the next.
    func plant(_ tab: Tab) async {
        _ = await js(tab, "document.cookie = 'browser=1; max-age=3600; path=/'; localStorage.setItem('browser', '1')", in: .page)
    }

    /// "cookie storage" if both are still there.
    func read(_ tab: Tab) async -> String {
        await js(tab, "(document.cookie.includes('browser=1') ? 'cookie ' : '') + (localStorage.getItem('browser') ? 'storage' : '')", in: .page) as? String ?? "?"
    }

    /// What a userscript left on the page's root element under `key`.
    func dataset(_ tab: Tab, _ key: String) async -> String {
        await js(tab, "document.documentElement.dataset.\(key) ?? 'none'") as? String ?? "?"
    }

    /// The page showing, or the page area for a tab with none.
    var selectedView: NSView { browser.selected?.webView ?? shell.pageArea }
    /// A blank tab's new tab page is up.
    var newTabPageShown: Bool { !shell.newTabPage.isHidden && shell.pageArea.stage.isHidden && shell.pageArea.isClear }
    /// How many download rows the sidebar shows.
    var downloadRows: Int { shell.sidebar.downloadRows.isHidden ? 0 : shell.sidebar.downloadRows.rows.count }
}
#endif
