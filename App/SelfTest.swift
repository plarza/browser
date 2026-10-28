#if DEBUG
import AppKit
import CoreKit
import WebKit

/// Debug builds only: `-coreSelfTest YES` drives the real window with real
/// key and mouse events, through AppKit's own dispatch (menus, responders,
/// field editors), and logs PASS or FAIL for each thing a person would do.
@MainActor
enum SelfTest {
    static func run(_ browser: BrowserWindowController) {
        guard UserDefaults.standard.bool(forKey: "coreSelfTest"), let window = browser.window else { return }
        Task { @MainActor in
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            browser.open(URL(string: "https://en.wikipedia.org/wiki/WebKit")!)
            try? await Task.sleep(for: .seconds(4))
            for _ in 0 ..< 20 where !window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(250))
            }

            // Clicking the address field once selects the whole address.
            click(browser.addressFieldForTesting, in: window)
            try? await Task.sleep(for: .milliseconds(300))
            let editor = window.firstResponder as? NSTextView
            let text = editor?.string ?? ""
            let range = editor?.selectedRange() ?? NSRange()
            check("click selects the whole address", editor != nil && text.hasPrefix("https://") && range.location == 0 && range.length == (text as NSString).length,
                  "text=\(text) selection=\(range)")

            // Clicking the page leaves the field.
            click(browser.selectedWebViewForTesting, in: window)
            try? await Task.sleep(for: .milliseconds(300))
            check("click on the page leaves the field", !(window.firstResponder is NSTextView) && !browser.addressFieldForTesting.isEditing,
                  "firstResponder=\(String(describing: window.firstResponder))")

            // ⌘L selects everything, and a click on the page leaves again.
            key("l", in: window)
            try? await Task.sleep(for: .milliseconds(300))
            let lEditor = window.firstResponder as? NSTextView
            check("⌘L selects the whole address", lEditor != nil && lEditor!.selectedRange().length == (lEditor!.string as NSString).length && lEditor!.string.hasPrefix("https://"),
                  "firstResponder=\(String(describing: window.firstResponder))")
            click(browser.selectedWebViewForTesting, in: window)
            try? await Task.sleep(for: .milliseconds(300))
            check("click on the page after ⌘L leaves the field", !(window.firstResponder is NSTextView),
                  "firstResponder=\(String(describing: window.firstResponder))")

            // ⌘S hides the sidebar with the page focused, and shows it again.
            window.makeFirstResponder(browser.selectedWebViewForTesting)
            let before = browser.sidebarShownForTesting
            key("s", in: window)
            try? await Task.sleep(for: .milliseconds(600))
            check("⌘S hides the sidebar", before && !browser.sidebarShownForTesting, "before=\(before) after=\(browser.sidebarShownForTesting)")
            key("s", in: window)
            try? await Task.sleep(for: .milliseconds(600))
            check("⌘S shows it again", browser.sidebarShownForTesting, "after=\(browser.sidebarShownForTesting)")

            // Favicon: the tab has one once the page has loaded.
            for _ in 0 ..< 20 where browser.selectedTab.flatMap({ Favicons.shared.icon(for: $0.url) }) == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            check("the tab shows the site's icon", browser.selectedTab.flatMap { Favicons.shared.icon(for: $0.url) } != nil, "")

            // ⌘H: History in a new tab, native, searchable.
            key("h", in: window)
            try? await Task.sleep(for: .seconds(1))
            let history = HistoryModel.shared
            check("⌘H opens History with entries", browser.selectedTab?.url?.absoluteString == "about://history"
                  && browser.pageShownForTesting == "history" && !history.results.isEmpty,
                  "url=\(browser.selectedTab?.url?.absoluteString ?? "nil") page=\(browser.pageShownForTesting ?? "none") rows=\(history.results.count)")
            history.query = "webkit wikipedia"
            check("History search finds the page by title and address", history.results.first?.title.contains("WebKit") == true,
                  "first=\(history.results.first?.title ?? "none")")
            history.query = "zzzz-nothing"
            check("History search with no match shows nothing", history.results.isEmpty, "rows=\(history.results.count)")
            history.query = ""

            let jar = await storage(browser)
            // Turning Persist off, and closing, deletes the tab's jar from disk.
            var left = await WKWebsiteDataStore.allDataStoreIdentifiers
            for _ in 0 ..< 30 where jar.map({ left.contains($0) }) == true {
                try? await Task.sleep(for: .seconds(1))
                left = await WKWebsiteDataStore.allDataStoreIdentifiers
            }
            check("a Persist tab's jar is deleted once it's done with", jar.map { !left.contains($0) } == true, "left=\(left.count)")

            // ⌘, opens about://settings; an engine's button saves it.
            key(",", in: window)
            try? await Task.sleep(for: .seconds(1))
            check("⌘, opens about://settings", browser.selectedTab?.url?.absoluteString == "about://settings" && browser.pageShownForTesting == "settings",
                  "url=\(browser.selectedTab?.url?.absoluteString ?? "nil") page=\(browser.pageShownForTesting ?? "none")")
            // Its "Add domain" row is a text field taking the row's width, not
            // a label beside a sliver of field.
            try? await Task.sleep(for: .milliseconds(500))
            func fields(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { [$0] } ?? [] + v.subviews.flatMap(fields) }
            let adder = fields(browser.pageHostForTesting).first { $0.placeholderString == "Add domain" || $0.placeholderAttributedString?.string == "Add domain" }
            check("Settings' Add domain row is a full-width field", adder.map { $0.isEditable && $0.frame.width > 200 } == true,
                  "field=\(adder.map { "\($0.frame)" } ?? "none")")
            // Typing in it, then clicking the page's empty margin, lets go of it.
            if let adder {
                click(adder, in: window)
                try? await Task.sleep(for: .milliseconds(300))
                let typing = (window.firstResponder as? NSTextView)?.delegate === adder
                click(browser.pageHostForTesting, in: window, at: NSPoint(x: 6, y: browser.pageHostForTesting.bounds.midY))
                try? await Task.sleep(for: .milliseconds(300))
                check("clicking off Settings' add field lets go of it", typing && !(window.firstResponder is NSTextView),
                      "typing=\(typing) firstResponder=\(String(describing: window.firstResponder))")
            }
            SearchEngine.all[0].choose()
            check("choosing a search engine in Settings saves it", Preferences.shared.settings.searchTemplate.contains("google.com"),
                  "template=\(Preferences.shared.settings.searchTemplate)")

            // A two-finger swipe right goes back; a short one doesn't.
            let first = URL(string: "https://example.com/")!
            let swiper = browser.newTab(first)
            try? await Task.sleep(for: .seconds(3))
            swiper.load(URL(string: "https://example.org/")!)
            try? await Task.sleep(for: .seconds(3))
            // The gesture's phases, as the scroll monitor passes them on.
            browser.swipeForTesting(.began, dx: 20)
            for _ in 0 ..< 8 { browser.swipeForTesting(.changed, dx: 25) }
            browser.swipeForTesting(.ended, dx: 0)
            try? await Task.sleep(for: .seconds(3))
            check("a two-finger swipe right goes back", swiper.url?.host == "example.com", "url=\(swiper.url?.absoluteString ?? "nil")")
            browser.swipeForTesting(.began, dx: -20)
            browser.swipeForTesting(.changed, dx: -30)
            browser.swipeForTesting(.ended, dx: 0)
            try? await Task.sleep(for: .seconds(2))
            check("a short swipe left doesn't go forward", swiper.url?.host == "example.com", "url=\(swiper.url?.absoluteString ?? "nil")")

            // A mouse's forward button goes forward, as ⌘] does.
            browser.mouseButtonForTesting(4)
            try? await Task.sleep(for: .seconds(3))
            check("the mouse's forward button goes forward", swiper.url?.host == "example.org", "url=\(swiper.url?.absoluteString ?? "nil")")
            browser.mouseButtonForTesting(3)
            try? await Task.sleep(for: .seconds(3))
            check("the mouse's back button goes back", swiper.url?.host == "example.com", "url=\(swiper.url?.absoluteString ?? "nil")")

            // Typing fills in a site you've been to, and lists pages from history.
            let field = browser.addressFieldForTesting
            field.focus()
            let typing = window.fieldEditor(true, for: field) as? NSTextView
            typing?.selectAll(nil)
            await type("en.wik", in: window)
            let filled = typing?.string ?? ""
            let filledSelection = typing?.selectedRange() ?? NSRange()
            check("typing fills in the rest of a visited site's name", filled == "en.wikipedia.org" && filledSelection == NSRange(location: 6, length: 10),
                  "text=\(filled) selection=\(filledSelection)")
            await type("\u{7f}", in: window)
            check("Delete removes what was filled in", typing?.string == "en.wik", "text=\(typing?.string ?? "nil")")
            typing?.selectAll(nil)
            await type("webkit", in: window)
            let listed = field.suggestions.visits
            check("history suggestions match by title", field.suggestions.isShown && listed.first?.title.contains("WebKit") == true,
                  "shown=\(field.suggestions.isShown) first=\(listed.first?.title ?? "none")")
            window.makeFirstResponder(nil)
            check("leaving the field hides the suggestions", !field.suggestions.isShown || field.suggestions.alphaValue < 1, "shown=\(field.suggestions.isShown)")

            let long = browser.newTab(URL(string: "https://en.wikipedia.org/wiki/WebKit")!)
            try? await Task.sleep(for: .seconds(4))

            // Find on page counts every match and steps through them.
            var found: (Int, Int?) = (0, nil)
            long.onFind = { found = ($0, $1) }
            long.find("WebKit")
            try? await Task.sleep(for: .seconds(1))
            let firstFind = found
            long.find("WebKit")
            try? await Task.sleep(for: .milliseconds(500))
            check("find on page counts matches and moves to the next", firstFind.0 > 5 && firstFind.1 == 0 && found.1 == 1,
                  "first=\(firstFind) then=\(found)")
            long.hideFind()

            // ⇧⌘I opens Web Inspector for the page.
            browser.select(long)
            browser.showInspector(nil)
            try? await Task.sleep(for: .seconds(2))
            let inspector = long.webView.value(forKey: "_inspector") as? NSObject
            check("⇧⌘I opens Web Inspector", (inspector?.value(forKey: "isVisible") as? Bool) == true, "")
            inspector?.perform(NSSelectorFromString("close"))
            browser.close(long)

            // A blank tab's search, then Back, is the new tab page again.
            let searched = browser.newTab(nil, focus: false)
            searched.load(URL(string: "https://example.com/")!)
            try? await Task.sleep(for: .seconds(2))
            searched.goBack()
            try? await Task.sleep(for: .milliseconds(500))
            check("Back from a blank tab's first page shows the new tab page", searched.url == nil && browser.newTabPageShownForTesting && searched.canGoForward,
                  "url=\(searched.url?.absoluteString ?? "nil") shown=\(browser.newTabPageShownForTesting)")
            browser.close(searched)

            // A page that sends itself on by script, unclicked, takes its own
            // place in Back's list.
            let redirected = browser.newTab(nil, focus: false)
            redirected.load(URL(string: "https://example.com/")!)
            try? await Task.sleep(for: .seconds(2))
            // From a timer the page set: script run by the app itself counts as a
            // click to WebKit, and so do timers for a second after it.
            _ = try? await redirected.webView.evaluateJavaScript("setTimeout(() => location.replace('https://example.org/'), 1500)", in: nil, contentWorld: .page)
            try? await Task.sleep(for: .seconds(4))
            let afterRedirect = redirected.entries.map(\.absoluteString)
            redirected.goBack()
            try? await Task.sleep(for: .milliseconds(500))
            check("a script redirect replaces its entry, so Back reaches the new tab page",
                  afterRedirect == ["about:newtab", "https://example.org/"] && redirected.url == nil, "entries=\(afterRedirect) url=\(redirected.url?.absoluteString ?? "nil")")
            browser.close(redirected)

            // The same with a real Google search from a blank tab.
            Preferences.shared.settings.searchTemplate = "https://www.google.com/search?q=%s"
            let googled = browser.newTab(nil, focus: false)
            if case .go(let url)? = Address.resolve("webkit browser engine", searchTemplate: Preferences.shared.settings.searchTemplate) { googled.load(url) }
            try? await Task.sleep(for: .seconds(6))
            let googleEntries = googled.entries.map { $0.host ?? $0.absoluteString }
            googled.goBack()
            try? await Task.sleep(for: .seconds(1))
            check("Back after a Google search from a blank tab reaches the new tab page", googled.url == nil && browser.newTabPageShownForTesting,
                  "entries=\(googleEntries) url=\(googled.url?.absoluteString ?? "nil")")
            browser.close(googled)

            // An extension installs from the Chrome Web Store: fetched,
            // signature checked, unpacked.
            if let id = UserDefaults.standard.string(forKey: "coreInstall") {
                for _ in 0 ..< 40 where !Extensions.shared.installed.contains(where: { $0.id == id }) && Extensions.shared.trouble == nil {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                check("an extension installs from the Chrome Web Store", Extensions.shared.installed.contains { $0.id == id },
                      "trouble=\(Extensions.shared.trouble ?? "none")")
            }

            // The Chrome Web Store offers "Add to Core".
            let store = browser.newTab(URL(string: "https://chromewebstore.google.com/detail/ghmbeldphafepmbegfdlkpapadhbakde")!)
            var label = ""
            for _ in 0 ..< 20 where !label.contains("to Core") {
                try? await Task.sleep(for: .milliseconds(500))
                label = (try? await store.webView.evaluateJavaScript("(document.querySelector('button[data-core=\"add\"]') || {}).textContent || ''", in: nil, contentWorld: .defaultClient) as? String) ?? ""
            }
            check("the Chrome Web Store's button says Add to Core", label.contains("to Core"), "label=\(label)")
            browser.close(store)

            // Dragging the first tab down two places moves it there; the
            // selected tab stays selected.
            if let table = browser.tabTableForTesting, browser.tabs.count >= 3 {
                let moving = browser.tabs[0], keep = browser.selectedTab
                let rowHeight = table.rowHeight + table.intercellSpacing.height
                func point(_ y: CGFloat) -> NSPoint { table.convert(NSPoint(x: 40, y: y), to: nil) }
                func mouse(_ type: NSEvent.EventType, _ y: CGFloat) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point(y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                let start = rowHeight / 2
                for step in 1 ... 10 { NSApp.postEvent(mouse(.leftMouseDragged, start + rowHeight * 2.2 * CGFloat(step) / 10), atStart: false) }
                NSApp.postEvent(mouse(.leftMouseUp, start + rowHeight * 2.2), atStart: false)
                table.mouseDown(with: mouse(.leftMouseDown, start))
                try? await Task.sleep(for: .milliseconds(400))
                check("dragging a tab moves it, keeping the selection", browser.tabs[2] === moving && browser.selectedTab === keep,
                      "index=\(browser.tabs.firstIndex { $0 === moving } ?? -1)")
                // The lifted row is a visible picture of the tab: its title's
                // dark pixels, not an empty frame.
                var ink = 0
                if let image = TabTable.lastLift, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                            if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5, c.brightnessComponent < 0.5 { ink += 1 }
                        }
                    }
                    if let folder = UserDefaults.standard.string(forKey: "coreShots") {
                        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("lifted-tab.png"))
                    }
                }
                check("a dragged tab stays visible while it moves", ink > 20, "ink=\(ink)")
            }

            // ⇧⌘↑ from the first tab goes round to the last; ⇧⌘↓ back to the first.
            let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
            let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
            browser.select(browser.tabs[0])
            key(up, in: window, modifiers: [.command, .shift])
            check("⇧⌘↑ on the first tab goes to the last", browser.selectedTab === browser.tabs.last, "")
            key(down, in: window, modifiers: [.command, .shift])
            check("⇧⌘↓ on the last tab goes to the first", browser.selectedTab === browser.tabs.first, "")

            // A blank tab shows the new tab page; a page replaces it.
            let blankTab = browser.newTab(nil, focus: false)
            try? await Task.sleep(for: .milliseconds(500))
            let shownBlank = browser.newTabPageShownForTesting
            blankTab.load(URL(string: "https://example.com/")!)
            try? await Task.sleep(for: .seconds(2))
            check("a blank tab shows the new tab page, and a page replaces it", shownBlank && !browser.newTabPageShownForTesting,
                  "blank=\(shownBlank) after=\(browser.newTabPageShownForTesting)")
            browser.close(blankTab)

            // New tabs go where Settings says.
            Preferences.shared.settings.newTabPosition = .top
            let atTop = browser.newTab(nil, focus: false)
            Preferences.shared.settings.newTabPosition = .bottom
            let atBottom = browser.newTab(nil, focus: false)
            browser.select(browser.tabs[1])
            Preferences.shared.settings.newTabPosition = .below
            let below = browser.newTab(nil, focus: false)
            check("new tabs open at the top, the bottom, or below the current one",
                  browser.tabs.first === atTop && browser.tabs.last === atBottom && browser.tabs[2] === below, "")
            for tab in [atTop, atBottom, below] { browser.close(tab) }

            // The filter lists, fetched at launch, compile into the blocker.
            for _ in 0 ..< 120 where Blocker.shared.ruleCount == 0 && Blocker.shared.trouble == nil {
                try? await Task.sleep(for: .seconds(1))
            }
            check("the filter lists compile into the blocker", Blocker.shared.ruleCount > 100_000 && Blocker.shared.trouble == nil,
                  "rules=\(Blocker.shared.ruleCount) trouble=\(Blocker.shared.trouble ?? "none")")

            // Pauses on each screen, for a screenshot from outside.
            if UserDefaults.standard.string(forKey: "coreShots") != nil {
                let wiki = browser.newTab(URL(string: "https://en.wikipedia.org/wiki/WebKit")!)
                try? await Task.sleep(for: .seconds(4))
                swiper.persist = true
                browser.select(wiki)
                await shot("page", browser)
                try? await Task.sleep(for: .seconds(4))
                let field = browser.addressFieldForTesting
                field.focus()
                let editor = window.fieldEditor(true, for: field) as? NSTextView
                await type("wik", in: window)
                try? await Task.sleep(for: .milliseconds(500))
                await shot("suggest", browser)
                try? await Task.sleep(for: .seconds(4))
                window.makeFirstResponder(nil)
                browser.showHistory(nil)
                try? await Task.sleep(for: .seconds(1))
                await shot("history", browser)
                try? await Task.sleep(for: .seconds(4))
                let empty = browser.newTab(nil, focus: false)
                Preferences.shared.settings.newTabPage = .image
                try? await Task.sleep(for: .seconds(1))
                await shot("newtab", browser)
                try? await Task.sleep(for: .seconds(4))
                Preferences.shared.settings.newTabPage = .blank
                try? await Task.sleep(for: .seconds(1))
                await shot("frosted", browser)
                try? await Task.sleep(for: .seconds(4))
                Preferences.shared.settings.newTabPage = .image
                browser.close(empty)
            }
            // ⇧⌘/ opens about://help, listing the menus' own shortcuts.
            browser.showHelp(nil)
            try? await Task.sleep(for: .seconds(2))
            let shortcuts = (NSApp.mainMenu.map(Menus.shortcuts(in:)) ?? []).map { $0.joined(separator: " ") }.joined(separator: "\n")
            check("about://help lists the shortcuts", browser.pageShownForTesting == "help" && shortcuts.contains("Persist Tab ⌘I") && shortcuts.contains("Web Inspector ⇧⌘I") && !shortcuts.contains("Minimize"),
                  "page=\(browser.pageShownForTesting ?? "none") shortcuts=\(shortcuts.replacingOccurrences(of: "\n", with: " | "))")
            await shot("help", browser)

            // Icons of sites in History are kept on disk; clearing History
            // deletes them.
            let wikiIcon = Favicons.shared.file(for: "en.wikipedia.org")
            let iconKept = FileManager.default.fileExists(atPath: wikiIcon.path)
            History.shared.remove("https://en.wikipedia.org/wiki/WebKit")
            let stillKnown = History.shared.search("en.wikipedia.org").isEmpty == false
            History.shared.clear()
            check("a site's icon is kept on disk while it's in History, and cleared with it",
                  iconKept && !FileManager.default.fileExists(atPath: wikiIcon.path), "kept=\(iconKept) otherVisits=\(stillKnown)")

            // Fill: the new tab page's picture under the whole window, the
            // sidebar frosted over it.
            Preferences.shared.settings.fill = true
            let fillTab = browser.newTab(nil, focus: false)
            try? await Task.sleep(for: .seconds(1))
            check("Fill puts the picture behind a frosted sidebar", browser.fillsForTesting, "")
            await shot("fill-newtab", browser)
            browser.close(fillTab)
            browser.select(browser.tabs[0])
            try? await Task.sleep(for: .seconds(1))
            await shot("fill-page", browser)
            Preferences.shared.settings.fill = false

            browser.showSettings(nil)
            try? await Task.sleep(for: .seconds(1))
            await shot("settings", browser)
            NSLog("Core self-test: done")
        }
    }

    /// The wipe, Persist and the whitelist, with a cookie and localStorage.
    @discardableResult
    static func storage(_ browser: BrowserWindowController) async -> UUID? {
        let site = URL(string: "https://example.com/")!
        func settle(_ tab: Tab) async {
            try? await Task.sleep(for: .milliseconds(800))
            for _ in 0 ..< 40 where tab.isLoading { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .milliseconds(400))
        }
        func plant(_ tab: Tab) async {
            _ = try? await tab.webView.evaluateJavaScript("document.cookie = 'core=1; max-age=3600; path=/'; localStorage.setItem('core', '1')", in: nil, contentWorld: .page)
        }
        func read(_ tab: Tab) async -> String {
            (try? await tab.webView.evaluateJavaScript("(document.cookie.includes('core=1') ? 'cookie ' : '') + (localStorage.getItem('core') ? 'storage' : '')", in: nil, contentWorld: .page) as? String) ?? "?"
        }

        let tab = browser.newTab(site)
        await settle(tab)
        await plant(tab)
        let planted = await read(tab)
        tab.reload()
        await settle(tab)
        let afterWipe = await read(tab)
        check("a reload wipes cookies and storage", planted == "cookie storage" && afterWipe.isEmpty, "planted=\(planted) after=\(afterWipe)")

        tab.persist = true
        await plant(tab)
        tab.reload()
        await settle(tab)
        let persisted = await read(tab)
        check("Persist keeps them through a reload", persisted == "cookie storage", "after=\(persisted)")

        // A Persist tab is saved with its jar on disk and comes back with it,
        // as after quitting and reopening.
        let jar = tab.keptIdentity
        browser.saveTabs()
        let saved = OpenTabs.restore().tabs.contains { $0.kept?.id == jar?.id && $0.kept?.seed == jar?.seed }
        let reopened = browser.newTab(nil, select: false, focus: false, restoring: true)
        reopened.restore(site, kept: jar)
        browser.select(reopened)
        await settle(reopened)
        let reread = await read(reopened)
        check("a Persist tab comes back after quitting with its cookies and storage", jar != nil && saved && reopened.persist && reread == "cookie storage",
              "jar=\(jar != nil) saved=\(saved) after=\(reread)")
        browser.close(reopened)
        tab.persist = false

        Preferences.shared.settings.whitelist = ["example.com"]
        tab.load(site)
        await settle(tab)
        await plant(tab)
        tab.reload()
        await settle(tab)
        let kept = await read(tab)
        let other = browser.newTab(site)
        await settle(other)
        let shared = await read(other)
        check("a whitelisted site keeps them, in every tab", kept == "cookie storage" && shared == "cookie storage", "same tab=\(kept) other tab=\(shared)")
        Preferences.shared.settings.whitelist = []
        try? await Task.sleep(for: .milliseconds(500))
        other.load(site)
        await settle(other)
        let forgotten = await read(other)
        check("taking a site off the whitelist forgets its jar", forgotten.isEmpty, "after=\(forgotten)")

        return jar?.id
    }

    /// `-coreShots <folder>`: Core's window, and only Core's window, into
    /// <folder>/<name>.png, while it sits behind other windows.
    static func shot(_ name: String, _ browser: BrowserWindowController) async {
        guard let folder = UserDefaults.standard.string(forKey: "coreShots"), let window = browser.window,
              let frame = window.contentView?.superview else { return }
        // macOS doesn't draw a window it thinks nobody can see, and SwiftUI
        // then draws nothing. Lifted on top but all but transparent (and
        // ignoring the mouse) it draws; then back behind everything at full
        // opacity, where the window server still holds what it drew.
        let level = window.level
        window.ignoresMouseEvents = true
        window.alphaValue = 0.02
        window.level = .floating
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(600))
        window.level = level
        window.orderBack(nil)
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        try? await Task.sleep(for: .milliseconds(80))
        // The window server's own picture of this window, and nothing else:
        // what AppKit, WebKit and SwiftUI all drew, composited. Only this
        // window's number is asked for, so no other app can be in it. (The
        // call is hidden from the SDK, not from macOS.)
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
              let image = unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
        else { NSLog("Core self-test: shot \(name) failed"); return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    /// `-coreProbe <url> -coreProbeOut <file>`: loads the page, lets it
    /// settle, writes what it shows; then reloads (a wipe) and writes it again.
    static func probe(_ browser: BrowserWindowController) {
        guard let address = UserDefaults.standard.string(forKey: "coreProbe"), let url = URL(string: address),
              let out = UserDefaults.standard.string(forKey: "coreProbeOut") else { return }
        Task { @MainActor in
            let tab = browser.newTab(url)
            var report = ""
            for pass in 1 ... 2 {
                try? await Task.sleep(for: .seconds(35))
                let text = try? await tab.webView.evaluateJavaScript("document.body.innerText", in: nil, contentWorld: .defaultClient) as? String
                report += "===== PASS \(pass)\n\(text ?? "(nothing)")\n"
                try? report.write(toFile: out, atomically: true, encoding: .utf8)
                if pass == 1 { tab.reload() }
            }
            NSLog("Core probe: done")
        }
    }

    static func check(_ name: String, _ ok: Bool, _ detail: String) {
        NSLog("Core self-test: \(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — \(detail)")")
    }

    static func click(_ view: NSView, in window: NSWindow, at local: NSPoint? = nil) {
        let point = view.convert(local ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // The up goes in the queue first, for the tracking loop the down starts.
        // Straight to the window, as AppKit routes a click in the key window
        // (macOS won't make a test window key while someone works elsewhere).
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        NSApp.sendEvent(mouse(.leftMouseDown))
    }

    /// A trackpad swipe: horizontal scroll events with gesture phases.
    /// Real key presses, one at a time, through the window as typing is.
    static func type(_ text: String, in window: NSWindow) async {
        for ch in text {
            let c = String(ch)
            let code: UInt16 = c == "\u{7f}" ? 51 : 0
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c,
                                         isARepeat: false, keyCode: code)!
                window.sendEvent(e)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .milliseconds(200))
    }

    static func key(_ character: String, in window: NSWindow, modifiers: NSEvent.ModifierFlags = .command) {
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                                    isARepeat: false, keyCode: ["s": 1, "l": 37, "y": 16, String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): 126,
                                                                String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): 125][character] ?? 0)!
        // What NSApp does with a ⌘-key for the key window.
        if !window.performKeyEquivalent(with: down) { window.sendEvent(down) }
    }
}
#endif
