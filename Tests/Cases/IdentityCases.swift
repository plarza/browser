#if DEBUG
import AppKit
import BrowserKit
import WebKit

/// A tab's identity: the wipe, Persist and its jar, links within a site,
/// the whitelist, and what comes back after quitting.
extension SelfTest {
    var identityCases: [Case] {
        [
            Case("wipe and Persist") { await self.wipeAndPersist() },
            Case("tabs saved and restored") { await self.savedAndRestored() },
            Case("same-site links") { await self.sameSiteLinks() },
            Case("Persist jar deleted") { await self.persistJarDeleted() },
            Case("closing a Persist tab") { await self.closingAPersistTab() },
            Case("whitelist") { await self.whitelist() },
        ]
    }

    /// The wipe and Persist, with a cookie and localStorage.
    private func wipeAndPersist() async {
        let site = server.url("/page/one")
        guard let tab = browser.selected else { return }
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
        await shown()
        let row = shell.sidebar.tabList.table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? TabRow
        await expect("a Persist tab's row turns sky blue", { row?.layer?.sublayers?.contains { ($0 as? CAGradientLayer)?.opacity == 1 } == true })
    }

    /// The open tabs as tabs.json has them, read back the way the next
    /// launch reads them: a Persist tab in its jar, any other tab fresh.
    private func savedAndRestored() async {
        let kept = server.url("/page/one"), plain = server.url("/page/two")
        let persist = await open(kept)
        persist.persist = true
        await go(persist, kept) { persist.reload() }
        await plant(persist)
        let other = await open(plain)
        await plant(other)
        let jar = persist.keptIdentity
        browser.save()
        struct Saved: Decodable {
            struct Tab: Decodable {
                let url: URL
                let jar: UUID?
            }

            let tabs: [Tab]
        }
        let saved = (try? Data(contentsOf: Store.url("tabs.json"))).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        check("the open tabs are saved, a Persist tab with its jar",
              jar != nil && saved?.tabs.contains { $0.url == kept && $0.jar == jar } == true && saved?.tabs.contains { $0.url == plain && $0.jar == nil } == true,
              "saved=\(saved?.tabs.map { "\($0.url.path) \($0.jar != nil)" } ?? [])")

        // The next launch's restore, beside the tabs still open.
        let open = browser.tabs
        browser.restore()
        let restored = browser.tabs.filter { tab in !open.contains { $0 === tab } }
        guard let again = restored.first(where: { $0.url == kept }), let fresh = restored.first(where: { $0.url == plain }) else {
            return check("the saved tabs come back", false, "restored=\(restored.compactMap { $0.url?.path })")
        }
        check("restored tabs are asleep until shown", again.pending == kept && fresh.pending == plain && !again.isLoading && !fresh.isLoading)
        check("a reopened tab shows the page's title from History before it loads",
              !again.title.isEmpty && again.title == persist.title && again.title != kept.host, "restored=\(again.title) page=\(persist.title)")
        check("a Persist tab comes back on Persist, in its jar", again.persist && again.keptIdentity == jar && fresh.keptIdentity == nil && !fresh.persist)
        await go(again, kept) { browser.select(again) }
        let reread = await read(again)
        check("a Persist tab comes back after quitting with its cookies and storage", reread == "cookie storage", "after=\(reread)")
        await go(fresh, plain) { browser.select(fresh) }
        let nothing = await read(fresh)
        check("any other tab comes back in a fresh identity", nothing.isEmpty, "after=\(nothing)")
    }

    /// Links within a site keep its identity and web view; another site, or
    /// coming back to the first, starts a new one.
    private func sameSiteLinks() async {
        let one = server.url("/page/one"), two = server.url("/page/two")
        guard let tab = browser.selected else { return }
        await go(tab, one) { tab.load(one) }
        await plant(tab)
        let view = tab.webView
        await go(tab, two) { follow(tab, two) }
        let kept = await read(tab)
        check("a link within the site keeps its cookies, storage and web view", kept == "cookie storage" && tab.webView === view, "after=\(kept)")
        let elsewhere = server.url("/page/three", on: server.other)
        await go(tab, elsewhere) { follow(tab, elsewhere) }
        let there = await read(tab)
        check("a link to another site starts a new identity", there.isEmpty && tab.webView !== view, "after=\(there)")
        await go(tab, two) { tab.goBack() }
        let back = await read(tab)
        check("Back to the first site doesn't bring its identity back", back.isEmpty, "after=\(back)")
    }

    private func persistJarDeleted() async {
        let one = server.url("/page/one")
        // The tab only ever held here, so the test's own hold doesn't keep it.
        weak var closed: Tab?
        var jar: UUID?
        do {
            let tab = await open(one)
            await plant(tab)
            tab.persist = true
            await go(tab, one) { tab.reload() }
            closed = tab
            jar = tab.keptIdentity
        }
        guard let jar else { return check("a Persist tab has a jar", false) }
        await expect("a Persist tab has a jar on disk", { await WKWebsiteDataStore.allDataStoreIdentifiers.contains(jar) })
        if let tab = closed { browser.close(tab) }
        await expect("a closed tab is let go of, web view and all", { closed == nil })
        await expect("a closed Persist tab's jar is deleted", seconds: 40, { !(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(jar)) })
    }

    private func closingAPersistTab() async {
        let tab = await open(server.url("/page/one"))
        tab.persist = true
        shell.commands.closeTab(nil)
        await expect("closing a Persist tab asks first", { window.attachedSheet != nil })
        escape()
        await expect("Escape keeps it", { window.attachedSheet == nil })
        check("…and the tab stays open", browser.tabs.contains { $0 === tab })
        shell.commands.closeTab(nil)
        await expect("it asks again", { window.attachedSheet != nil })
        confirm("Close Tab")
        await expect("Return closes the tab", { window.attachedSheet == nil && !browser.tabs.contains { $0 === tab } })
    }

    /// A whitelisted site keeps one jar for all its tabs, until it comes off the list.
    private func whitelist() async {
        let site = server.url("/page/one")
        Preferences.shared.settings.whitelist = ["localhost"]
        guard let tab = browser.selected else { return }
        await go(tab, site) { tab.load(site) }
        await plant(tab)
        await go(tab, site) { tab.reload() }
        let kept = await read(tab)
        let other = browser.newTab()
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
}
#endif
