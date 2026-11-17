#if DEBUG
import AppKit
import BrowserKit
import WebKit

/// The page area: a page's dialogs, back and forward by swipe and by
/// mouse, find, Web Inspector, and what shows when no page does.
extension SelfTest {
    var pageCases: [Case] {
        [
            Case("page alert") { await self.pageAlert() },
            Case("back and forward") { await self.backAndForward() },
            Case("a new tab shows nothing of another") { await self.newTabShowsNothingOfAnother() },
            Case("find and inspector") { await self.findAndInspector() },
            Case("Back to the new tab page") { await self.backToTheNewTabPage() },
            Case("new tab page") { await self.newTabPage() },
        ]
    }

    private var one: URL { server.url("/page/one") }
    private var two: URL { server.url("/page/two") }

    private func pageAlert() async {
        let tab = await open(one)
        run(tab, "setTimeout(() => alert('hi'), 0)")
        await expect("a page's alert is a sheet", { window.attachedSheet != nil })
        escape()
        await expect("Escape dismisses a page's alert", { window.attachedSheet == nil })
    }

    private func backAndForward() async {
        let swipes = shell.swipes
        let tab = await open(one)
        await go(tab, two) { tab.load(two) }
        // The gesture's phases, as the scroll monitor passes them on.
        await go(tab, one) {
            swipes.follow(.began, dx: 20, dy: 0)
            for _ in 0 ..< 8 { swipes.follow(.changed, dx: 25, dy: 0) }
            swipes.follow(.ended, dx: 0, dy: 0)
        }
        check("a two-finger swipe right goes back", tab.url == one, "url=\(tab.url?.absoluteString ?? "nil")")
        await expect("the swipe's picture goes once the page before has drawn", { !tab.view.isHolding && tab.view.subviews.count == 1 })
        // A little way and slowly, then let go: the page slides back.
        let stage = shell.pageArea.stage
        swipes.follow(.began, dx: -20, dy: 0)
        swipes.follow(.changed, dx: -10, dy: 0)
        check("a swipe left brings the page after in beside the page", stage.subviews.count == 2 && tab.view.frame.minX < 0,
              "stage=\(stage.subviews.count) x=\(tab.view.frame.minX)")
        swipes.follow(.ended, dx: 0, dy: 0)
        await expect("a short swipe left settles back, the page in place and alone", { tab.view.frame == stage.bounds && stage.subviews.count == 1 },
                     "frame=\(tab.view.frame) stage=\(stage.subviews.count)")
        check("…and doesn't go forward", tab.url == one && !tab.isLoading && tab.backForward.entries.last == two && tab.canGoForward,
              "url=\(tab.url?.absoluteString ?? "nil")")
        // No further, but fast: a flick.
        await go(tab, two) {
            swipes.follow(.began, dx: -20, dy: 0)
            swipes.follow(.changed, dx: -30, dy: 0)
            swipes.follow(.ended, dx: 0, dy: 0)
        }
        check("a flick left goes forward", tab.url == two && !tab.canGoForward, "url=\(tab.url?.absoluteString ?? "nil")")
        await go(tab, one) { shell.mouseButton(3) }
        check("the mouse's back button goes back", tab.url == one, "url=\(tab.url?.absoluteString ?? "nil")")
        await go(tab, two) { shell.mouseButton(4) }
        check("the mouse's forward button goes forward", tab.url == two, "url=\(tab.url?.absoluteString ?? "nil")")
    }

    private func newTabShowsNothingOfAnother() async {
        let swipes = shell.swipes, stage = shell.pageArea.stage
        let tab = await open(one)
        await go(tab, two) { tab.load(two) }
        // Nothing of a page sits in the page area outside the stage,
        // and the stage holds the selected tab's page alone.
        let onlySelected = { (name: String) in
            await self.shown()
            let strays = self.shell.pageArea.subviews.filter { $0 is PageView || $0 is NSImageView }
            self.check(name, strays.isEmpty && stage.subviews.count == 1 && stage.subviews.first === self.browser.selected?.view,
                       "strays=\(strays.count) stage=\(stage.subviews.count)")
        }
        // A swipe whose end never comes (the fingers left the
        // trackpad over the sidebar), and a second one on top of it.
        swipes.follow(.began, dx: 20, dy: 0)
        swipes.follow(.changed, dx: 25, dy: 0)
        swipes.follow(.began, dx: 20, dy: 0)
        swipes.follow(.changed, dx: 25, dy: 0)
        key("t")
        let blank = browser.selected
        await expect("⌘T selects a blank tab", { blank !== tab && blank?.url == nil })
        await onlySelected("a new tab during a swipe holds no other tab's page or picture")
        await expect("a blank tab shows the new tab page, not a page", { stage.isHidden && !shell.newTabPage.isHidden })
        swipes.follow(.ended, dx: 0, dy: 0)
        await onlySelected("the old swipe ending in another tab leaves nothing behind")
        check("the old swipe ending in another tab doesn't navigate it", tab.url == two, "url=\(tab.url?.absoluteString ?? "nil")")
        browser.select(tab)
        await onlySelected("going back to the tab shows its page alone")
        check("its page is back in place", tab.view.frame == stage.bounds, "frame=\(tab.view.frame)")
        if let blank { browser.select(blank) }
        await onlySelected("and a blank tab again, nothing of it")
        if let blank { browser.close(blank) }
        await onlySelected("closing a blank tab shows the next one alone")
        await shot("new tab after swipe")
    }

    private func findAndInspector() async {
        let tab = await open(server.url("/page/WebKit-Test-Page"))
        tab.find("WebKit")
        await expect("find on page counts the matches", { tab.found?.matches == 13 && tab.found?.current == 0 }, "found=\(String(describing: tab.found))")
        tab.find("WebKit")
        await expect("find again moves to the next", { tab.found?.current == 1 }, "found=\(String(describing: tab.found))")
        tab.hideFind()

        // The find bar itself: ⌘F, typing, Return, Escape.
        let bar = shell.pageArea.findBar
        key("f")
        await expect("⌘F shows the find bar, with the keyboard", { !bar.isHidden && window.firstResponder is NSTextView })
        await type("engine")
        await expect("typing in the find bar counts the matches on the page", { tab.found?.matches == 12 }, "found=\(String(describing: tab.found))")
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        await expect("Escape puts the find bar away and gives the page the keyboard", { bar.isHidden && window.firstResponder === tab.webView && tab.found == nil })

        window.makeFirstResponder(tab.webView)
        key("I", modifiers: [.command, .shift])
        let inspector = tab.webView.value(forKey: "_inspector") as? NSObject
        check("opening Web Inspector makes this page inspectable", tab.webView.isInspectable)
        await expect("⇧⌘I opens a connected Web Inspector", {
            (inspector?.value(forKey: "isVisible") as? Bool) == true && (inspector?.value(forKey: "isConnected") as? Bool) == true
        })
        var frontend: WKWebView?
        await expect("Web Inspector loads its frontend", {
            frontend = NSApp.windows.lazy.compactMap { window in
                window.contentView.flatMap { self.views(WKWebView.self, in: $0).first { $0.url?.scheme == "inspector-resource" } }
            }.first
            guard let frontend else { return false }
            let text = try? await frontend.evaluateJavaScript("document.body.innerText") as? String
            return text?.contains("Elements") == true && text?.contains("Console") == true
        })
        if let frontend {
            for side in ["left", "bottom"] {
                _ = try? await frontend.evaluateJavaScript("InspectorFrontendHost.requestSetDockSide('\(side)')")
                await expect("Web Inspector docks to the \(side) without covering the page", seconds: 5, {
                    window.contentView?.layoutSubtreeIfNeeded()
                    let pageFrame = tab.webView.convert(tab.webView.bounds, to: nil)
                    let inspectorFrame = frontend.convert(frontend.bounds, to: nil)
                    return frontend.window === window && inspectorFrame.width > 100 && inspectorFrame.height > 100
                        && pageFrame.width > 100 && pageFrame.height > 100
                        && pageFrame.intersection(inspectorFrame).isEmpty
                }, "page=\(tab.webView.frame) inspector=\(frontend.frame)")
                // Docked, it has to stay put: layout must not push the page back over it.
                let frame = frontend.frame
                let moved = await until("the \(side) inspector to move, which it must not", seconds: 1) {
                    window.contentView?.layoutSubtreeIfNeeded()
                    return frontend.frame != frame || frontend.isHidden || (inspector?.value(forKey: "isConnected") as? Bool) != true
                }
                check("the \(side) inspector remains visible and stable", !moved, "frame=\(frontend.frame)")
            }
            window.makeFirstResponder(frontend)
            key("I", modifiers: [.command, .shift])
            await expect("⇧⌘I in the inspector closes it", { (inspector?.value(forKey: "isVisible") as? Bool) != true })
        }
        let restored = {
            self.window.contentView?.layoutSubtreeIfNeeded()
            return tab.webView.frame == tab.webView.superview?.bounds
        }
        await expect("closing Web Inspector restores the full page", { restored() })
        window.makeFirstResponder(tab.webView)
        key("I", modifiers: [.command, .shift])
        await expect("⇧⌘I reopens Web Inspector", { (inspector?.value(forKey: "isVisible") as? Bool) == true })
        window.makeFirstResponder(tab.webView)
        key("I", modifiers: [.command, .shift])
        await expect("⇧⌘I on the page closes it again", { (inspector?.value(forKey: "isVisible") as? Bool) != true && restored() })
    }

    private func backToTheNewTabPage() async {
        guard let tab = browser.selected else { return }
        await go(tab, one) { tab.load(one) }
        tab.goBack()
        await expect("Back from a blank tab's first page shows the new tab page", { tab.url == nil && newTabPageShown && tab.canGoForward },
                     "url=\(tab.url?.absoluteString ?? "nil")")
        let after = server.url("/page/after")
        await go(tab, after) { tab.load(server.url("/redirect")) }
        let entries = tab.backForward.entries.map(\.absoluteString)
        tab.goBack()
        check("a script redirect replaces its entry, so Back reaches the new tab page",
              entries == ["about:newtab", after.absoluteString] && tab.url == nil, "entries=\(entries)")
        guard case .go(let search)? = Address.resolve("webkit browser engine", searchTemplate: Preferences.shared.settings.searchTemplate) else {
            return check("words resolve to a search", false)
        }
        await go(tab, search) { tab.load(search) }
        tab.goBack()
        await expect("Back after a search from a blank tab reaches the new tab page", { tab.url == nil && newTabPageShown },
                     "url=\(tab.url?.absoluteString ?? "nil")")
        // A site that changes pages with pushState, as GitHub does.
        let app = server.url("/page/app")
        await go(tab, one) { tab.load(one) }
        await go(tab, app) { tab.load(app) }
        _ = await js(tab, "history.pushState(null, '', '/page/app-issues'); history.pushState(null, '', '/page/app-pulls')")
        let issues = server.url("/page/app-issues"), pulls = server.url("/page/app-pulls")
        await expect("pushState pages join the tab's back list", { tab.backForward.entries.suffix(3) == [app, issues, pulls] },
                     "entries=\(tab.backForward.entries.map(\.absoluteString))")
        await go(tab, issues) { tab.goBack() }
        check("Back after pushState reaches the site's previous page", tab.url == issues, "url=\(tab.url?.absoluteString ?? "nil")")
    }

    private func newTabPage() async {
        await expect("a blank tab shows the new tab page", { newTabPageShown })
        await shot("newtab")
        Preferences.shared.settings.newTabPage = .blank
        await expect("the Blank new tab page frosts the desktop through the window", { !window.isOpaque })
        await shot("frosted")
        Preferences.shared.settings.newTabPage = .image
        guard let tab = browser.selected else { return }
        await go(tab, one) { tab.load(one) }
        await expect("a page replaces the new tab page", { !newTabPageShown && shell.newTabPage.isHidden })
        await expect("a page shows in an opaque window", { window.isOpaque })
        await shot("page")
        browser.newTab()
        Preferences.shared.settings.fill = true
        let page = shell.newTabPage
        await expect("Fill puts the picture behind a frosted sidebar", {
            shell.fills && shell.sidebar.isClear && !page.isHidden && page.frame.minX == 0 && page.frame.width > shell.pageArea.frame.width
                && page.glassWidth == shell.sidebar.width
        })
        await shot("fill-newtab")
        key("s")
        await expect("hiding the sidebar takes its glass with it", { page.glassWidth == 0 })
        key("s")
        await expect("…and showing it brings the glass back", { page.glassWidth == shell.sidebar.width })
    }
}
#endif
