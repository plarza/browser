import AppKit
import BrowserKit
import WebKit

/// The tab shows a `.user.js` file as text: read it, and offer it in the
/// install bar. Install, or Update or Reinstall when a script with the same
/// @name and @namespace is installed already.
@MainActor
final class InstallOffer {
    /// A script someone opened, read from the page showing it.
    private struct Script {
        let webView: WKWebView
        let url: URL
        let source: String?
        let meta: UserscriptMeta?
        /// Why JavaScriptCore can't parse it, if it can't.
        let error: String?
    }

    var onOpenUserscripts: () -> Void = {}
    private let browser: Browser
    private let bar: InstallBar
    /// The script the bar offers, and the address being read for the next.
    private var script: Script?
    private var reading: URL?
    private var following: Observer?

    init(browser: Browser, bar: InstallBar) {
        self.browser = browser
        self.bar = bar
        bar.onButton = { [weak self] in self?.install() }
        following = Observer { [weak self] in
            // Installing or removing a script changes what the bar offers.
            _ = Userscripts.shared.scripts
            self?.update()
        }
    }

    private func update() {
        let tab = browser.selected
        guard let tab, tab.page == nil, !tab.isLoading, let url = tab.url, url.path.lowercased().hasSuffix(".user.js") else {
            if let script, script.webView === tab?.webView {
                inset(script.webView, false)
                self.script = nil
            }
            bar.isHidden = true
            return
        }
        let webView = tab.webView
        if let script, script.webView === webView, script.url == url { return offer() }
        bar.isHidden = true
        guard reading != url else { return }
        reading = url
        Task {
            let read = "document.contentType.startsWith('text/html') ? null : (document.body ? document.body.textContent : null)"
            let text = try? await webView.evaluateJavaScript(read, in: nil, contentWorld: .defaultClient) as? String
            reading = nil
            guard webView.url == url else { return }
            let meta = text.flatMap(UserscriptMeta.parse)
            let error = meta.flatMap { meta in text.flatMap { Userscripts.syntaxError($0, meta) } }
            script = Script(webView: webView, url: url, source: meta == nil ? nil : text, meta: meta, error: error)
            offer()
        }
    }

    private func offer() {
        guard let script, script.webView === browser.selected?.webView, browser.selected?.page == nil,
              let source = script.source, let meta = script.meta
        else {
            bar.isHidden = true
            return
        }
        let existing = Userscripts.shared.installed(like: source)
        let detail = script.error ?? [meta.version, "Runs on " + meta.sites].filter { !$0.isEmpty }.joined(separator: " · ")
        let title = meta.name.isEmpty ? "Untitled script" : meta.name
        let installable = script.error == nil && !meta.name.isEmpty
        if existing?.source == source {
            bar.show(title: title, detail: "Installed · " + detail, button: "Open Userscripts", enabled: true, prominent: false)
        } else if let existing {
            let newer = UserscriptMeta.newer(meta.version, than: existing.meta.version)
            bar.show(title: title, detail: detail, button: newer ? "Update" : "Reinstall", enabled: installable, prominent: true)
        } else {
            bar.show(title: title, detail: detail, button: "Install", enabled: installable, prominent: true)
        }
        bar.isHidden = false
        inset(script.webView, true)
    }

    /// The page scrolls under the bar instead of starting behind it.
    private func inset(_ webView: WKWebView, _ on: Bool) {
        webView.obscuredContentInsets = NSEdgeInsets(top: on ? InstallBar.height : 0, left: 0, bottom: 0, right: 0)
    }

    /// The bar's button: install what it offers, or show the script
    /// already installed.
    private func install() {
        guard let script, let source = script.source else { return }
        if let existing = Userscripts.shared.installed(like: source), existing.source == source {
            UserscriptsModel.shared.selected = existing.id
            return onOpenUserscripts()
        }
        bar.button.isEnabled = false
        bar.button.title = "Installing…"
        Task {
            do {
                let installed = try await Userscripts.shared.install(source, from: script.url)
                UserscriptsModel.shared.selected = installed.id
                offer()
            } catch {
                bar.show(title: script.meta?.name ?? "", detail: error.localizedDescription, button: "Try Again", enabled: true, prominent: true)
            }
        }
    }
}
