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
            let found = try? await web?.evaluateJavaScript("[...document.querySelectorAll('li .title')].map(e => e.textContent).join('|')", in: nil, contentWorld: .page) as? String
            check("History search finds the page by title and address", found?.contains("WebKit") == true, "found=\(found ?? "nil")")
            _ = try? await web?.evaluateJavaScript("q.value = 'zzzz-nothing'; q.dispatchEvent(new Event('input'))", in: nil, contentWorld: .page)
            try? await Task.sleep(for: .milliseconds(600))
            let none = try? await web?.evaluateJavaScript("document.querySelectorAll('li').length", in: nil, contentWorld: .page) as? Int
            check("History search with no match shows nothing", none == 0, "rows=\(none ?? -1)")

            await storage(browser)

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

    static func key(_ character: String, in window: NSWindow, modifiers: NSEvent.ModifierFlags = .command) {
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                                    isARepeat: false, keyCode: ["s": 1, "l": 37, "y": 16][character] ?? 0)!
        // What NSApp does with a ⌘-key for the key window.
        if !window.performKeyEquivalent(with: down) { window.sendEvent(down) }
    }
}
#endif
