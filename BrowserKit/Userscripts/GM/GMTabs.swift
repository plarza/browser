import Foundation

/// GM_openInTab, with the `close()` and `onclose` of what it returns, and
/// the `window.close` and `window.focus` grants.
@MainActor
final class GMTabs {
    /// A tab a script opened, and the copy of the script to tell when it closes.
    private struct Opened {
        weak var tab: Tab?
        let opener: UserscriptInstance
    }

    /// By the name the script knows each tab by.
    private var opened: [String: Opened] = [:]

    /// Opens a tab in a fresh identity, beside the script's own, and
    /// answers with a name for it.
    func open(_ call: UserscriptCall) throws(UserscriptRefusal) -> Any? {
        guard call.grants.contains("openintab"), let tab = Tab.showing(call.webView),
              let url = call.url("url", schemes: ["https", "http"])
        else { throw .notGranted }
        guard let browser = tab.browser else { return nil }
        let active = call.arguments["active"] as? Bool ?? true
        let name = UUID().uuidString
        opened[name] = Opened(tab: browser.newTab(url, after: tab, select: active), opener: call.instance)
        return name
    }

    /// `close()` on what GM_openInTab returned.
    func close(_ call: UserscriptCall) {
        guard call.grants.contains("openintab"), let name = call.string("tab"), let tab = opened[name]?.tab else { return }
        tab.browser?.close(tab)
    }

    /// The script's own `window.close()`: its tab closes, without asking.
    func closeWindow(_ call: UserscriptCall) throws(UserscriptRefusal) {
        let tab = try ownTab(call, grant: "window.close")
        tab.browser?.close(tab)
    }

    /// The script's own `window.focus()`: its tab comes to the front.
    func focusWindow(_ call: UserscriptCall) throws(UserscriptRefusal) {
        let tab = try ownTab(call, grant: "window.focus")
        tab.browser?.focus(tab)
    }

    /// The tab a call came from, for a script in its top frame with `grant`.
    private func ownTab(_ call: UserscriptCall, grant: String) throws(UserscriptRefusal) -> Tab {
        guard call.grants.contains(grant), let tab = Tab.showing(call.webView), call.instance.frame.isMainFrame else { throw .notGranted }
        return tab
    }

    /// A tab closed: the scripts that opened it hear `onclose`.
    func closed(_ tab: Tab) {
        for (name, entry) in opened where entry.tab === tab || entry.tab == nil {
            opened[name] = nil
            Task { await entry.opener.push(["type": "tabclosed", "tab": name]) }
        }
    }
}
