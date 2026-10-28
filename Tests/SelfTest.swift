#if DEBUG
import AppKit
import BrowserKit
import WebKit

/// Debug builds only: `-browserSelfTest YES` drives the real window with real
/// key and mouse events, through AppKit's own dispatch (menus, responders,
/// field editors), and logs PASS or FAIL for each thing a person would do.
///
/// Every page it loads comes from `TestServer`, on this Mac. It never sleeps
/// for a guessed time: each step waits until what it expects is true, and
/// says what it is waiting for when that takes more than two seconds. Each
/// case starts from a clean window, and a dialog left open fails it.
@MainActor
enum SelfTest {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "browserSelfTest") }
    private static var server: TestServer!
    private static var passed = 0, failed = 0

    /// Before anything starts: the local site, and settings pointing at it,
    /// so not even the launch's filter-list fetch reaches the internet.
    static func prepare() {
        guard enabled else { return }
        server = TestServer()
        Preferences.shared.settings = settings
    }

    private static var settings: Settings {
        var settings = Settings()
        settings.filterLists = [server.url("/filters.txt").absoluteString]
        settings.searchTemplate = server.site + "/search?q=%s"
        return settings
    }

    static func run(_ browser: BrowserWindowController) {
        guard enabled, let window = browser.window else { return }
        Task { @MainActor in
            for (name, body) in cases(browser, window) {
                await reset(browser, window)
                // A case that never finishes fails, and the next one runs.
                var finished = false
                let run = Task { @MainActor in await body(); finished = true }
                if !(await until("the \(name) case to finish", seconds: 240) { finished }) {
                    run.cancel()
                    check("the \(name) case finishes", false, "")
                }
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                    check("\(name): no dialog left open", false, "")
                }
            }
            NSLog("Browser self-test: done, \(passed) passed, \(failed) failed")
        }
    }

    /// One blank tab, the test's settings, nothing in History, Downloads or any field.
    private static func reset(_ browser: BrowserWindowController, _ window: NSWindow) async {
        for tab in browser.tabs { browser.close(tab) }
        Preferences.shared.settings = settings
        History.shared.clear()
        HistoryModel.shared.query = ""
        Downloads.shared.dismissAllForTesting()
        // Nothing the last case started still running into this one.
        await until("icon fetches to finish") { !Favicons.shared.isFetching }
        if !browser.sidebarShownForTesting { browser.toggleBrowserSidebar(nil) }
        window.makeFirstResponder(nil)
    }

    // MARK: Cases

    private static func cases(_ browser: BrowserWindowController, _ window: NSWindow) -> [(String, () async -> Void)] {
        let page = server.url("/page/WebKit-Test-Page")
        let one = server.url("/page/one"), two = server.url("/page/two")
        func open(_ url: URL) async -> Tab {
            let tab = browser.newTab(nil, focus: false)
            await go(tab, url) { tab.load(url) }
            return tab
        }
        return [
            ("address field", {
                _ = await open(page)
                let field = browser.addressFieldForTesting
                click(field, in: window)
                let editor = { window.firstResponder as? NSTextView }
                await expect("click selects the whole address", {
                    editor().map { $0.string == page.absoluteString && $0.selectedRange() == NSRange(location: 0, length: ($0.string as NSString).length) } == true
                }, "text=\(editor()?.string ?? "nil") selection=\(editor()?.selectedRange() ?? NSRange())")
                click(browser.selectedWebViewForTesting, in: window)
                await expect("click on the page leaves the field", { !(window.firstResponder is NSTextView) && !field.isEditing })
                await key("l", in: window)
                await expect("⌘L selects the whole address", {
                    editor().map { $0.selectedRange().length == ($0.string as NSString).length && $0.string == page.absoluteString } == true
                })
                click(browser.selectedWebViewForTesting, in: window)
                await expect("click on the page after ⌘L leaves the field", { !(window.firstResponder is NSTextView) })
            }),
            ("sidebar", {
                await key("s", in: window)
                check("⌘S hides the sidebar", !browser.sidebarShownForTesting, "")
                await key("s", in: window)
                check("⌘S shows it again", browser.sidebarShownForTesting, "")
            }),
            ("site icon", {
                let tab = await open(page)
                await expect("the tab shows the site's icon", { Favicons.shared.icon(for: tab.url) != nil })
                let file = Favicons.shared.file(for: "localhost")
                await expect("a site's icon is kept on disk while it's in History", { FileManager.default.fileExists(atPath: file.path) })
                History.shared.clear()
                check("clearing History deletes its icons", !FileManager.default.fileExists(atPath: file.path), "")
            }),
            ("history page", {
                _ = await open(page)
                await key("h", in: window)
                let history = HistoryModel.shared
                await expect("⌘H opens History with entries", {
                    browser.selectedTab?.url?.absoluteString == "about://history" && browser.pageShownForTesting == "history" && !history.results.isEmpty
                }, "url=\(browser.selectedTab?.url?.absoluteString ?? "nil") rows=\(history.results.count)")
                history.query = "webkit localhost"
                check("History search finds the page by title and address", history.results.first?.title == "WebKit Test Page",
                      "first=\(history.results.first?.title ?? "none")")
                history.query = "zzzz-nothing"
                check("History search with no match shows nothing", history.results.isEmpty, "rows=\(history.results.count)")
                await shot("history", browser)
            }),
            ("wipe and Persist", { await wipeAndPersist(browser, one) }),
            ("Persist jar deleted", {
                // The tab only ever held here, so the test's own hold doesn't keep it.
                weak var closed: Tab?
                let jar: UUID? = await {
                    let tab = await open(one)
                    await plant(tab)
                    tab.persist = true
                    await go(tab, one) { tab.reload() }
                    closed = tab
                    return tab.keptIdentity?.id
                }()
                guard let jar else { return check("a Persist tab has a jar", false, "") }
                await expect("a Persist tab has a jar on disk", { await WKWebsiteDataStore.allDataStoreIdentifiers.contains(jar) })
                if let tab = closed { browser.close(tab) }
                await expect("a closed tab is let go of, web view and all", { closed == nil })
                await expect("a closed Persist tab's jar is deleted", seconds: 40, { !(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(jar)) })
            }),
            ("closing a Persist tab", {
                let tab = await open(one)
                tab.persist = true
                browser.closeTabAction(nil)
                await expect("closing a Persist tab asks first", { window.attachedSheet != nil })
                escape(window)
                await expect("Escape keeps it", { window.attachedSheet == nil })
                check("…and the tab stays open", browser.tabs.contains { $0 === tab }, "")
                browser.closeTabAction(nil)
                await expect("it asks again", { window.attachedSheet != nil })
                await confirm(window, "Close Tab")
                await expect("Return closes the tab", { window.attachedSheet == nil && !browser.tabs.contains { $0 === tab } })
            }),
            ("page alert", {
                let tab = await open(one)
                tab.webView.evaluateJavaScript("setTimeout(() => alert('hi'), 0)", in: nil, in: .page)
                await expect("a page's alert is a sheet", { window.attachedSheet != nil })
                escape(window)
                await expect("Escape dismisses a page's alert", { window.attachedSheet == nil })
            }),
            ("whitelist", { await whitelist(browser, one) }),
            ("settings", {
                await key(",", in: window)
                check("⌘, opens about://settings", browser.selectedTab?.url?.absoluteString == "about://settings" && browser.pageShownForTesting == "settings",
                      "page=\(browser.pageShownForTesting ?? "none")")
                func fields(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { [$0] } ?? [] + v.subviews.flatMap(fields) }
                var adder: NSTextField?
                // A row as wide as the form, not a label beside a sliver of field.
                await expect("Settings' Add domain row is a full-width field", {
                    adder = fields(browser.pageHostForTesting).first { $0.placeholderString == "Add domain" || $0.placeholderAttributedString?.string == "Add domain" }
                    return adder.map { $0.isEditable && $0.frame.width > 200 } == true
                })
                if let adder {
                    click(adder, in: window)
                    await expect("clicking Settings' add field types in it", { (window.firstResponder as? NSTextView)?.delegate === adder })
                    click(browser.pageHostForTesting, in: window, at: NSPoint(x: 6, y: browser.pageHostForTesting.bounds.midY))
                    await expect("clicking off it lets go of it", { !(window.firstResponder is NSTextView) })
                }
                SearchEngine.all[0].choose()
                check("choosing a search engine in Settings saves it", Preferences.shared.settings.searchTemplate.contains("google.com"),
                      "template=\(Preferences.shared.settings.searchTemplate)")
                Preferences.shared.settings.fill = true
                await shot("settings", browser)
            }),
            ("back and forward", {
                let tab = await open(one)
                await go(tab, two) { tab.load(two) }
                // The gesture's phases, as the scroll monitor passes them on.
                await go(tab, one) {
                    browser.swipeForTesting(.began, dx: 20)
                    for _ in 0 ..< 8 { browser.swipeForTesting(.changed, dx: 25) }
                    browser.swipeForTesting(.ended, dx: 0)
                }
                check("a two-finger swipe right goes back", tab.url == one, "url=\(tab.url?.absoluteString ?? "nil")")
                // Going forward would swap the web view at once; it stays.
                let view = tab.webView
                browser.swipeForTesting(.began, dx: -20)
                browser.swipeForTesting(.changed, dx: -30)
                browser.swipeForTesting(.ended, dx: 0)
                check("a short swipe left doesn't go forward", tab.webView === view && tab.url == one, "url=\(tab.url?.absoluteString ?? "nil")")
                await go(tab, two) { browser.mouseButtonForTesting(4) }
                check("the mouse's forward button goes forward", tab.url == two, "url=\(tab.url?.absoluteString ?? "nil")")
                await go(tab, one) { browser.mouseButtonForTesting(3) }
                check("the mouse's back button goes back", tab.url == one, "url=\(tab.url?.absoluteString ?? "nil")")
            }),
            ("typing in the address field", {
                _ = await open(page)
                let field = browser.addressFieldForTesting
                field.focus()
                let editor = window.fieldEditor(true, for: field) as? NSTextView
                editor?.selectAll(nil)
                await type("localh", in: window)
                await expect("typing fills in the rest of a visited site's name", {
                    editor?.string == "localhost" && editor?.selectedRange() == NSRange(location: 6, length: 3)
                }, "text=\(editor?.string ?? "nil") selection=\(editor?.selectedRange() ?? NSRange())")
                await type("\u{7f}", in: window)
                check("Delete removes what was filled in", editor?.string == "localh", "text=\(editor?.string ?? "nil")")
                editor?.selectAll(nil)
                await type("webkit", in: window)
                await expect("history suggestions match by title", { field.suggestions.isShown && field.suggestions.visits.first?.title == "WebKit Test Page" })
                await shot("suggest", browser)
                window.makeFirstResponder(nil)
                check("leaving the field hides the suggestions", !field.suggestions.isShown || field.suggestions.alphaValue < 1, "")
            }),
            ("find and inspector", {
                let tab = await open(page)
                var found: (Int, Int?) = (0, nil)
                tab.onFind = { found = ($0, $1) }
                tab.find("WebKit")
                await expect("find on page counts the matches", { found.0 == 13 && found.1 == 0 }, "found=\(found)")
                tab.find("WebKit")
                await expect("find again moves to the next", { found.1 == 1 }, "found=\(found)")
                tab.hideFind()
                browser.showInspector(nil)
                let inspector = tab.webView.value(forKey: "_inspector") as? NSObject
                await expect("⇧⌘I opens Web Inspector", { (inspector?.value(forKey: "isVisible") as? Bool) == true })
                inspector?.perform(NSSelectorFromString("close"))
            }),
            ("Back to the new tab page", {
                let tab = browser.selectedTab!
                await go(tab, one) { tab.load(one) }
                tab.goBack()
                check("Back from a blank tab's first page shows the new tab page", tab.url == nil && browser.newTabPageShownForTesting && tab.canGoForward,
                      "url=\(tab.url?.absoluteString ?? "nil")")
                let after = server.url("/page/after")
                await go(tab, after) { tab.load(server.url("/redirect")) }
                let entries = tab.entries.map(\.absoluteString)
                tab.goBack()
                check("a script redirect replaces its entry, so Back reaches the new tab page",
                      entries == ["about:newtab", after.absoluteString] && tab.url == nil, "entries=\(entries)")
                guard case .go(let search)? = Address.resolve("webkit browser engine", searchTemplate: Preferences.shared.settings.searchTemplate) else {
                    return check("words resolve to a search", false, "")
                }
                await go(tab, search) { tab.load(search) }
                tab.goBack()
                check("Back after a search from a blank tab reaches the new tab page", tab.url == nil && browser.newTabPageShownForTesting,
                      "url=\(tab.url?.absoluteString ?? "nil")")
            }),
            ("tab list", {
                _ = await open(one)
                _ = await open(two)
                guard let table = browser.tabTableForTesting else { return check("the tab list is a table", false, "") }
                await expect("the tab list shows three rows", { table.numberOfRows == 3 })
                table.layoutSubtreeIfNeeded()
                let moving = browser.tabs[0], keep = browser.selectedTab
                drag(table, rows: 2.2, in: window)
                check("dragging a tab moves it, keeping the selection", browser.tabs[2] === moving && browser.selectedTab === keep,
                      "index=\(browser.tabs.firstIndex { $0 === moving } ?? -1)")
                check("a dragged tab stays visible while it moves", ink(TabTable.lastLift) > 20, "ink=\(ink(TabTable.lastLift))")
                let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
                let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
                browser.select(browser.tabs[0])
                await key(up, in: window, modifiers: [.command, .shift])
                check("⇧⌘↑ on the first tab goes to the last", browser.selectedTab === browser.tabs.last, "")
                await key(down, in: window, modifiers: [.command, .shift])
                check("⇧⌘↓ on the last tab goes to the first", browser.selectedTab === browser.tabs.first, "")
                Preferences.shared.settings.newTabPosition = .top
                let atTop = browser.newTab(nil, focus: false)
                Preferences.shared.settings.newTabPosition = .bottom
                let atBottom = browser.newTab(nil, focus: false)
                browser.select(browser.tabs[1])
                Preferences.shared.settings.newTabPosition = .below
                let below = browser.newTab(nil, focus: false)
                check("new tabs open at the top, the bottom, or below the current one",
                      browser.tabs.first === atTop && browser.tabs.last === atBottom && browser.tabs[2] === below, "")
            }),
            ("new tab page", {
                check("a blank tab shows the new tab page", browser.newTabPageShownForTesting, "")
                await shot("newtab", browser)
                Preferences.shared.settings.newTabPage = .blank
                await shot("frosted", browser)
                Preferences.shared.settings.newTabPage = .image
                let tab = browser.selectedTab!
                await go(tab, one) { tab.load(one) }
                check("a page replaces the new tab page", !browser.newTabPageShownForTesting, "")
                await shot("page", browser)
                browser.newTab(nil, focus: false)
                Preferences.shared.settings.fill = true
                await expect("Fill puts the picture behind a frosted sidebar", { browser.fillsForTesting })
                await shot("fill-newtab", browser)
            }),
            ("filter lists", {
                await expect("the filter lists compile into the blocker, split as WebKit needs", seconds: 60, {
                    Blocker.shared.ruleCount >= TestServer.ruleCount || Blocker.shared.trouble != nil
                })
                check("…with nothing going wrong", Blocker.shared.trouble == nil && Blocker.shared.ruleCount >= TestServer.ruleCount,
                      "rules=\(Blocker.shared.ruleCount) trouble=\(Blocker.shared.trouble ?? "none")")
                let tab = await open(one)
                let fetched = await js(tab, "fetch('/ad-banner.js').then(() => 'loaded', () => 'blocked')", in: .page, awaiting: true) as? String
                check("a request a list names is blocked", fetched == "blocked", "fetch=\(fetched ?? "no answer")")
            }),
            ("downloads", {
                Downloads.autoDismiss = 0.5
                defer { Downloads.autoDismiss = 60 }
                let tab = await open(one)
                tab.webView.evaluateJavaScript("location.href = '/download'", in: nil, in: .page)
                await expect("a download saves where asked and shows in the sidebar", {
                    let got = Downloads.shared.items.first
                    return got?.name == "browser-test.txt" && got?.state == .finished && got.map { FileManager.default.fileExists(atPath: $0.file.path) } == true
                }, "items=\(Downloads.shared.items.map(\.name))")
                await key("j", in: window)
                check("⌘J opens about://downloads", browser.pageShownForTesting == "downloads", "page=\(browser.pageShownForTesting ?? "none")")
                await expect("a done download leaves the sidebar by itself", { browser.downloadRowsForTesting == 0 })
                await shot("downloads", browser)
            }),
            ("download rows", {
                Downloads.shared.addForTesting(name: "Quarterly Report.pdf", received: 2_400_000, expected: 2_400_000, state: .finished)
                Downloads.shared.addForTesting(name: "ubuntu-26.04-desktop-arm64.iso", received: 1_900_000_000, expected: 6_100_000_000, state: .active)
                Downloads.shared.addForTesting(name: "photos-export.zip", received: 412_000_000, expected: 580_000_000, state: .active)
                await expect("the sidebar lists three downloads", { browser.downloadTilesForTesting.count == 3 })
                let tiles = browser.downloadTilesForTesting
                tiles.first?.hoverForTesting(true)
                check("a downloading row shows its size, and an x while hovered; a done one a minus",
                      tiles.count == 3 && tiles[0].accessory == "xmark" && tiles[1].accessory == "size" && tiles[2].accessory == "minus",
                      "accessories=\(tiles.map(\.accessory))")
                await shot("downloads-sidebar", browser)
                tiles.first?.hoverForTesting(false)
                tiles.last?.pressForTesting()
                await expect("the minus takes a done download off the sidebar", { browser.downloadRowsForTesting == 2 })
            }),
            ("help", {
                // ⇧⌘/ is Browser's help page, not macOS's Help menu search:
                // through NSApp, where the system would take it.
                NSApp.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, characters: "?", charactersIgnoringModifiers: "/",
                                                 isARepeat: false, keyCode: 44)!)
                check("⇧⌘/ opens about://help", browser.pageShownForTesting == "help", "page=\(browser.pageShownForTesting ?? "none")")
                let shortcuts = (NSApp.mainMenu.map(Menus.shortcuts(in:)) ?? []).map { $0.joined(separator: " ") }.joined(separator: "\n")
                check("about://help lists the shortcuts", shortcuts.contains("Persist Tab ⌘I") && shortcuts.contains("Web Inspector ⇧⌘I") && !shortcuts.contains("Minimize"),
                      "shortcuts=\(shortcuts.replacingOccurrences(of: "\n", with: " | "))")
                check("Browser's pages show the grey logo as their icon", Favicons.browser != nil && Favicons.shared.icon(for: URL(string: "about://help")) === Favicons.browser, "")
                await shot("help", browser)
            }),
        ]
    }

    /// The wipe and Persist, with a cookie and localStorage.
    private static func wipeAndPersist(_ browser: BrowserWindowController, _ site: URL) async {
        let tab = browser.selectedTab!
        await go(tab, site) { tab.load(site) }
        await plant(tab)
        let planted = await read(tab)
        await go(tab, site) { tab.reload() }
        let afterWipe = await read(tab)
        check("a reload wipes cookies and storage", planted == "cookie storage" && afterWipe.isEmpty, "planted=\(planted) after=\(afterWipe)")

        tab.persist = true
        await plant(tab)
        await go(tab, site) { tab.reload() }
        let persisted = await read(tab)
        check("Persist keeps them through a reload", persisted == "cookie storage", "after=\(persisted)")

        // Saved with its jar and seed, and back with them, as after quitting.
        let jar = tab.keptIdentity
        browser.saveTabs()
        let saved = OpenTabs.restore().tabs.contains { $0.kept?.id == jar?.id && $0.kept?.seed == jar?.seed }
        let reopened = browser.newTab(nil, select: false, focus: false, restoring: true)
        reopened.restore(site, kept: jar)
        await go(reopened, site) { browser.select(reopened) }
        let reread = await read(reopened)
        check("a Persist tab comes back after quitting with its cookies and storage", jar != nil && saved && reopened.persist && reread == "cookie storage",
              "jar=\(jar != nil) saved=\(saved) after=\(reread)")
    }

    /// A whitelisted site keeps one jar for all its tabs, until it comes off the list.
    private static func whitelist(_ browser: BrowserWindowController, _ site: URL) async {
        Preferences.shared.settings.whitelist = ["localhost"]
        let tab = browser.selectedTab!
        await go(tab, site) { tab.load(site) }
        await plant(tab)
        await go(tab, site) { tab.reload() }
        let kept = await read(tab)
        let other = browser.newTab(nil, focus: false)
        await go(other, site) { other.load(site) }
        let shared = await read(other)
        let elsewhere = server.url("/page/one", on: server.other)
        await go(other, elsewhere) { other.load(elsewhere) }
        let notThere = await read(other)
        check("a whitelisted site keeps them, in every tab, and no other site has them",
              kept == "cookie storage" && shared == "cookie storage" && notThere.isEmpty, "kept=\(kept) other tab=\(shared) other site=\(notThere)")
        Preferences.shared.settings.whitelist = []
        await go(other, site) { other.load(site) }
        let forgotten = await read(other)
        check("taking a site off the whitelist forgets its jar", forgotten.isEmpty, "after=\(forgotten)")
    }

    private static func plant(_ tab: Tab) async {
        _ = await js(tab, "document.cookie = 'browser=1; max-age=3600; path=/'; localStorage.setItem('browser', '1')", in: .page)
    }

    private static func read(_ tab: Tab) async -> String {
        await js(tab, "(document.cookie.includes('browser=1') ? 'cookie ' : '') + (localStorage.getItem('browser') ? 'storage' : '')", in: .page) as? String ?? "?"
    }

    /// Script in the tab's page, answered within five seconds or not at all:
    /// WebKit can leave a call unanswered (a web view that never loaded).
    /// With `awaiting`, `source` is an expression whose promise is awaited.
    static func js(_ tab: Tab, _ source: String, in world: WKContentWorld = .defaultClient, awaiting: Bool = false) async -> Any? {
        await withCheckedContinuation { done in
            var answered = false
            let answer = { (value: Any?) in if !answered { answered = true; done.resume(returning: value) } }
            if awaiting {
                tab.webView.callAsyncJavaScript("return await (\(source))", arguments: [:], in: nil, in: world) { answer(try? $0.get()) }
            } else {
                tab.webView.evaluateJavaScript(source, in: nil, in: world) { answer(try? $0.get()) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { answer(nil) }
        }
    }

    // MARK: Waiting

    /// Waits until `condition` holds, checking every 10 ms, for at most
    /// `seconds`; after two seconds it says what it is waiting for.
    @discardableResult
    static func until(_ what: String, seconds: Double = 15, _ condition: () async -> Bool) async -> Bool {
        let start = ContinuousClock.now
        var said = false
        while !(await condition()) {
            let waited = ContinuousClock.now - start
            if seconds.isFinite, waited > .seconds(seconds) { return false }
            if !said, waited > .seconds(2) { NSLog("Browser self-test: waiting for \(what)"); said = true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    static func expect(_ name: String, seconds: Double = 15, _ condition: () async -> Bool, _ detail: @autoclosure () -> String = "") async {
        check(name, await until(name, seconds: seconds, condition), detail())
    }

    /// Does `action`, then waits for the tab to have finished loading `url`
    /// as a new document: a mark left in the old one, in a world the page
    /// can't see, is gone.
    static func go(_ tab: Tab, _ url: URL, _ action: () -> Void) async {
        // A web view that never loaded has no document to mark, and any it
        // gets is new.
        if tab.webView.url != nil { _ = await js(tab, "window.__selfTest = true") }
        action()
        let arrived = await until("\(url.absoluteString) to load") {
            guard !tab.isLoading, tab.url == url else { return false }
            return await js(tab, "window.__selfTest ? '' : document.readyState + ' ' + location.href") as? String == "complete \(url.absoluteString)"
        }
        if !arrived { check("\(url.absoluteString) loads", false, "url=\(tab.url?.absoluteString ?? "nil") loading=\(tab.isLoading)") }
    }

    // MARK: Input

    static func check(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { passed += 1 } else { failed += 1 }
        NSLog("Browser self-test: \(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — \(detail)")")
    }

    static func click(_ view: NSView, in window: NSWindow, at local: NSPoint? = nil) {
        let point = view.convert(local ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // The up goes in the queue first, for the tracking loop the down starts.
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        NSApp.sendEvent(mouse(.leftMouseDown))
    }

    /// Presses on the first row and drags it down by `rows` rows: the drag
    /// and the release are queued for the table's own tracking loop.
    static func drag(_ table: NSTableView, rows: CGFloat, in window: NSWindow) {
        let height = table.rowHeight + table.intercellSpacing.height
        func mouse(_ type: NSEvent.EventType, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: table.convert(NSPoint(x: 40, y: y), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = height / 2
        for step in 1 ... 10 { NSApp.postEvent(mouse(.leftMouseDragged, start + height * rows * CGFloat(step) / 10), atStart: false) }
        NSApp.postEvent(mouse(.leftMouseUp, start + height * rows), atStart: false)
        table.mouseDown(with: mouse(.leftMouseDown, start))
    }

    /// Dark pixels in a picture: a tab's title drawn, not an empty frame.
    static func ink(_ image: NSImage?) -> Int {
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let rep = NSBitmapImageRep(cgImage: cg)
        return stride(from: 0, to: rep.pixelsWide, by: 2).reduce(0) { sum, x in
            sum + stride(from: 0, to: rep.pixelsHigh, by: 2).filter { y in
                rep.colorAt(x: x, y: y).map { $0.alphaComponent > 0.5 && $0.brightnessComponent < 0.5 } == true
            }.count
        }
    }

    /// Typed one key at a time, through the window as typing is; each key
    /// handled (and the main queue's follow-up work done) before the next.
    static func type(_ text: String, in window: NSWindow) async {
        for ch in text {
            let c = String(ch)
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c,
                                                  isARepeat: false, keyCode: c == "\u{7f}" ? 51 : 0)!)
            }
            await Task.yield()
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }
    }

    /// Escape, into the dialog in front, as the window hands it on.
    static func escape(_ window: NSWindow) {
        guard let sheet = window.attachedSheet else { return }
        sheet.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                         isARepeat: false, keyCode: 53)!)
    }

    /// Return, in the dialog in front. AppKit gives Return to a window's
    /// default button only while the window is key, which needs Browser to be
    /// the active app; so this checks that `title` is that button, and presses
    /// it as Return would, whichever app is in front.
    static func confirm(_ window: NSWindow, _ title: String) async {
        let button = window.attachedSheet?.defaultButtonCell
        check("Return is \(title)", button?.title == title, "default=\(button?.title ?? "none")")
        button?.performClick(nil)
    }

    /// A menu shortcut, as NSApp hands one to the key window.
    static func key(_ character: String, in window: NSWindow, modifiers: NSEvent.ModifierFlags = .command) async {
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                                    isARepeat: false, keyCode: ["s": 1, "l": 37, "y": 16, String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): 126,
                                                                String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): 125][character] ?? 0)!
        if !window.performKeyEquivalent(with: down) { window.sendEvent(down) }
    }

    /// `-browserShots <folder>`: Browser's window, and only Browser's window, into
    /// <folder>/<name>.png, while it sits behind other windows.
    static func shot(_ name: String, _ browser: BrowserWindowController) async {
        guard let folder = UserDefaults.standard.string(forKey: "browserShots"), let window = browser.window,
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
        else { NSLog("Browser self-test: shot \(name) failed"); return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    /// `-browserProbe <url> -browserProbeOut <file>`: loads the page, lets it
    /// settle, writes what it shows; then reloads (a wipe) and writes it again.
    static func probe(_ browser: BrowserWindowController) {
        guard let address = UserDefaults.standard.string(forKey: "browserProbe"), let url = URL(string: address),
              let out = UserDefaults.standard.string(forKey: "browserProbeOut") else { return }
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
            NSLog("Browser probe: done")
        }
    }

}
#endif
