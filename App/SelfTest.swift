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

            // ⌘Y: History in a new tab, searchable.
            key("y", in: window)
            try? await Task.sleep(for: .seconds(2))
            let web = browser.selectedTab?.webView
            let rows = try? await web?.evaluateJavaScript("document.querySelectorAll('li').length", in: nil, contentWorld: .page) as? Int
            check("⌘Y opens History with entries", browser.selectedTab?.url?.absoluteString == "about://history" && (rows ?? 0) > 0,
                  "url=\(browser.selectedTab?.url?.absoluteString ?? "nil") rows=\(rows ?? -1)")
            _ = try? await web?.evaluateJavaScript("q.value = 'webkit wikipedia'; q.dispatchEvent(new Event('input'))", in: nil, contentWorld: .page)
            try? await Task.sleep(for: .milliseconds(600))
            let found = try? await web?.evaluateJavaScript("[...document.querySelectorAll('li .t')].map(e => e.textContent).join('|')", in: nil, contentWorld: .page) as? String
            check("History search finds the page by title and address", found?.contains("WebKit") == true, "found=\(found ?? "nil")")
            _ = try? await web?.evaluateJavaScript("q.value = 'zzzz-nothing'; q.dispatchEvent(new Event('input'))", in: nil, contentWorld: .page)
            try? await Task.sleep(for: .milliseconds(600))
            let none = try? await web?.evaluateJavaScript("document.querySelectorAll('li').length", in: nil, contentWorld: .page) as? Int
            check("History search with no match shows nothing", none == 0, "rows=\(none ?? -1)")

            await storage(browser)

            // ⌘, opens about://settings; choosing a search engine there saves it.
            key(",", in: window)
            try? await Task.sleep(for: .seconds(2))
            let page = browser.selectedTab?.webView
            let sections = try? await page?.evaluateJavaScript("document.querySelectorAll('h2').length", in: nil, contentWorld: .page) as? Int
            check("⌘, opens about://settings", browser.selectedTab?.url?.absoluteString == "about://settings" && sections == 6,
                  "url=\(browser.selectedTab?.url?.absoluteString ?? "nil") sections=\(sections ?? -1)")
            _ = try? await page?.evaluateJavaScript("document.querySelector('#picks button').click()", in: nil, contentWorld: .page)
            try? await Task.sleep(for: .milliseconds(500))
            let fixed = try? await page?.evaluateJavaScript("[...document.querySelectorAll('textarea')].every(t => getComputedStyle(t).resize === 'none' && t.offsetHeight >= 190)", in: nil, contentWorld: .page) as? Bool
            check("the Settings text boxes are tall and fixed", fixed == true, "fixed=\(String(describing: fixed))")
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

            // Scrolling animates: a Space on a long page passes through several
            // positions on its way down instead of jumping there.
            let long = browser.newTab(URL(string: "https://en.wikipedia.org/wiki/WebKit")!)
            try? await Task.sleep(for: .seconds(4))
            window.makeFirstResponder(long.webView)
            let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                         isARepeat: false, keyCode: 49)!
            window.sendEvent(space)
            var positions: [Double] = []
            for _ in 0 ..< 15 {
                if let y = try? await long.webView.evaluateJavaScript("scrollY", in: nil, contentWorld: .defaultClient) as? Double { positions.append(y) }
                try? await Task.sleep(for: .milliseconds(25))
            }
            let steps = Set(positions.filter { $0 > 0 && $0 < (positions.last ?? 0) }).count
            check("scrolling is smooth", steps >= 3, "positions=\(positions.map { Int($0) })")
            browser.close(long)

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
            if UserDefaults.standard.bool(forKey: "coreScreens") {
                let wiki = browser.newTab(URL(string: "https://en.wikipedia.org/wiki/WebKit")!)
                try? await Task.sleep(for: .seconds(4))
                swiper.persist = true
                browser.select(wiki)
                NSLog("Core self-test: SHOT page")
                try? await Task.sleep(for: .seconds(4))
                let field = browser.addressFieldForTesting
                field.focus()
                let editor = window.fieldEditor(true, for: field) as? NSTextView
                await type("wik", in: window)
                try? await Task.sleep(for: .milliseconds(500))
                NSLog("Core self-test: SHOT suggest")
                try? await Task.sleep(for: .seconds(4))
                window.makeFirstResponder(nil)
                browser.showHistory(nil)
                try? await Task.sleep(for: .seconds(1))
                NSLog("Core self-test: SHOT history")
                try? await Task.sleep(for: .seconds(4))
                let empty = browser.newTab(nil, focus: false)
                Preferences.shared.settings.newTabPage = .image
                try? await Task.sleep(for: .seconds(1))
                NSLog("Core self-test: SHOT newtab")
                try? await Task.sleep(for: .seconds(4))
                Preferences.shared.settings.newTabPage = .blank
                try? await Task.sleep(for: .seconds(1))
                NSLog("Core self-test: SHOT frosted")
                try? await Task.sleep(for: .seconds(4))
                Preferences.shared.settings.newTabPage = .image
                browser.close(empty)
            }
            browser.showSettings(nil)
            try? await Task.sleep(for: .seconds(1))
            NSLog("Core self-test: SHOT settings")
            NSLog("Core self-test: done")
        }
    }

    /// The wipe, Persist and the whitelist, with a cookie and localStorage.
    static func storage(_ browser: BrowserWindowController) async {
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

    static func click(_ view: NSView, in window: NSWindow) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
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
