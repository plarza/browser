#if DEBUG
import AppKit
import BrowserKit

/// Browser's own pages: about://history, about://settings and about://help.
extension SelfTest {
    var ownPageCases: [Case] {
        [
            Case("history page") { await self.historyPage() },
            Case("settings") { await self.settings() },
            Case("help") { await self.help() },
        ]
    }

    private func historyPage() async {
        let page = await open(server.url("/page/WebKit-Test-Page"))
        key("h")
        let history = HistoryModel.shared
        await expect("⌘H opens History with entries", {
            browser.selected?.url?.absoluteString == "about://history" && shell.pageArea.shownPage == .history && !history.results.isEmpty
        }, "url=\(browser.selected?.url?.absoluteString ?? "nil") rows=\(history.results.count)")
        check("History opens in a tab of its own", browser.selected !== page && browser.tabs.contains { $0 === page })
        history.query = "webkit localhost"
        await expect("History search finds the page by title and address", { history.results.first?.title == "WebKit Test Page" && history.results.count == 1 },
                     "first=\(history.results.first?.title ?? "none")")
        history.query = "zzzz-nothing"
        await expect("History search with no match shows nothing", { history.results.isEmpty }, "rows=\(history.results.count)")
        await shot("history")
        history.query = ""
        await expect("an empty search lists everything again", { history.results.count == 1 })
        History.shared.remove(page.url?.absoluteString ?? "")
        await expect("removing an entry takes it off the page", { history.results.isEmpty }, "rows=\(history.results.count)")
    }

    private func settings() async {
        key(",")
        let host = shell.pageArea.pageHost
        await expect("⌘, opens about://settings", { browser.selected?.url?.absoluteString == "about://settings" && shell.pageArea.shownPage == .settings },
                     "page=\(String(describing: shell.pageArea.shownPage))")
        var adder: NSTextField?
        // A row as wide as the form, not a label beside a sliver of field.
        await expect("Settings' Add domain row is a full-width field", {
            adder = views(NSTextField.self, in: host).first { $0.placeholderString == "Add domain" || $0.placeholderAttributedString?.string == "Add domain" }
            return adder.map { $0.isEditable && $0.frame.width > 200 } == true
        })
        if let adder {
            await click(adder)
            await expect("clicking Settings' add field types in it", { (window.firstResponder as? NSTextView)?.delegate === adder })
            await type("Example.com\r")
            await expect("Return adds the domain to the whitelist, as a bare host", { Preferences.shared.settings.whitelist == ["example.com"] },
                         "whitelist=\(Preferences.shared.settings.whitelist) field=\(adder.stringValue)")
            await click(host, at: NSPoint(x: 6, y: host.bounds.midY))
            await expect("clicking off it lets go of it", { !(window.firstResponder is NSTextView) })
        }
        SearchEngine.all[0].choose()
        check("choosing a search engine in Settings saves it", Preferences.shared.settings.searchTemplate.contains("google.com"),
              "template=\(Preferences.shared.settings.searchTemplate)")
        Preferences.shared.settings.appearance = .dark
        await expect("choosing Dark turns the whole app dark", { NSApp.appearance?.name == .darkAqua && shell.sidebar.isDark })
        Preferences.shared.settings.appearance = .system
        await expect("…and System follows macOS again", { NSApp.appearance == nil })
        Preferences.shared.settings.fill = true
        await shot("settings")
    }

    private func help() async {
        // ⇧⌘/ is Browser's help page, not macOS's Help menu search:
        // through NSApp, where the system would take it.
        appKey("?", ignoringModifiers: "/", modifiers: [.command, .shift], code: 44)
        await expect("⇧⌘/ opens about://help", { shell.pageArea.shownPage == .help }, "page=\(String(describing: shell.pageArea.shownPage))")
        let shortcuts = (NSApp.mainMenu.map { Shortcut.all(in: $0) } ?? []).map { "\($0.menu) \($0.title) \($0.keys)" }.joined(separator: "\n")
        check("about://help lists the shortcuts",
              shortcuts.contains("Persist Tab ⌘I") && shortcuts.contains("Web Inspector ⇧⌘I") && !shortcuts.contains("Minimize"),
              "shortcuts=\(shortcuts.replacingOccurrences(of: "\n", with: " | "))")
        check("a command with several keys lists them all",
              shortcuts.contains("Tab Next Tab ⇧⌘] or ⇧⌘↓ or ⌃⇥") && shortcuts.contains("Tab Previous Tab ⇧⌘[ or ⇧⌘↑ or ⌃⇧⇥"),
              "shortcuts=\(shortcuts.split(separator: "\n").filter { $0.contains("Tab ") }.joined(separator: " | "))")
        let pages = InternalPage.allCases.map { page in NSApp.mainMenu.map { Shortcut.keys(for: Commands.showing(page), in: $0) } ?? "" }
        check("…and its own pages' keys, read from the menus", pages == ["⌘H", "⌘J", "⌘,", "", "⇧⌘/"], "keys=\(pages)")
        check("Browser's pages show the grey logo as their icon",
              Favicons.browser != nil && Favicons.shared.icon(for: URL(string: "about://help")) === Favicons.browser)
        await shot("help")
    }
}
#endif
