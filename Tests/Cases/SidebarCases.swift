#if DEBUG
import AppKit
import BrowserKit

/// The sidebar: hiding it, the tabs' icons, and the tab list.
extension SelfTest {
    var sidebarCases: [Case] {
        [
            Case("sidebar") { await self.sidebar() },
            Case("the sidebar's edge") { await self.sidebarEdge() },
            Case("tab keys") { await self.tabKeys() },
            Case("site icon") { await self.siteIcon() },
            Case("tab list") { await self.tabList() },
        ]
    }

    private func sidebar() async {
        key("s")
        check("⌘S hides the sidebar", !shell.sidebar.isShown)
        key("s")
        check("⌘S shows it again", shell.sidebar.isShown)
    }

    /// The edge between the sidebar and the page drags, between 200 and 420 points.
    private func sidebarEdge() async {
        let sidebar = shell.sidebar
        let before = sidebar.width
        defer { UserDefaults.standard.set(Double(before), forKey: "sidebarWidth") }
        drag(sidebar.edge, across: 500)
        window.contentView?.layoutSubtreeIfNeeded()
        check("dragging the sidebar's edge right stops at 420 points", sidebar.width == 420 && sidebar.frame.width == 420 && shell.pageArea.frame.minX == 420,
              "width=\(sidebar.width) frame=\(sidebar.frame.width)")
        check("the width it was left at is kept for the next launch", UserDefaults.standard.double(forKey: "sidebarWidth") == 420)
        drag(sidebar.edge, across: -500)
        window.contentView?.layoutSubtreeIfNeeded()
        check("dragging it left stops at 200 points", sidebar.width == 200 && sidebar.frame.width == 200, "width=\(sidebar.width)")
        drag(sidebar.edge, across: before - 200)
        window.contentView?.layoutSubtreeIfNeeded()
        check("…and it follows the pointer in between", sidebar.width == before, "width=\(sidebar.width) before=\(before)")
    }

    /// The Tab and File menus' keys, and the middle button on a tab.
    private func tabKeys() async {
        let one = server.url("/page/one"), two = server.url("/page/two")
        let first = await open(one)
        let second = await open(two)
        let table = shell.sidebar.tabList.table
        key("1")
        check("⌘1 selects the first tab", browser.selected === browser.tabs[0])
        key("9")
        check("⌘9 selects the last", browser.selected === second)
        // Without ⌘ a key goes to the page first, and comes back to the
        // menus by a road only the app in front has. With nothing holding
        // the keyboard it goes straight to them.
        window.makeFirstResponder(nil)
        key(SelfTest.backTab, modifiers: [.control, .shift])
        check("⌃⇧Tab selects the tab before", browser.selected === first, "selected=\(browser.index(of: browser.selected) ?? -1)")
        key("\t", modifiers: .control)
        check("⌃Tab selects the tab after", browser.selected === second, "selected=\(browser.index(of: browser.selected) ?? -1)")
        key("\t", modifiers: .control)
        check("…and goes round from the last tab to the first", browser.selected === browser.tabs[0], "selected=\(browser.index(of: browser.selected) ?? -1)")
        key(SelfTest.backTab, modifiers: [.control, .shift])
        check("…as ⌃⇧Tab does from the first to the last", browser.selected === second, "selected=\(browser.index(of: browser.selected) ?? -1)")
        key("d")
        await expect("⌘D duplicates the tab, below it", {
            browser.tabs.count == 4 && browser.selected !== second && browser.selected?.url == two && browser.index(of: browser.selected) == (browser.index(of: second) ?? -1) + 1
        }, "tabs=\(browser.tabs.map { $0.url?.path ?? "blank" })")
        guard let copy = browser.selected else { return }
        await shown()
        key("w")
        await expect("⌘W closes the tab and shows the one after, or the last", { !browser.tabs.contains { $0 === copy } && browser.selected === second },
                     "tabs=\(browser.tabs.map { $0.url?.path ?? "blank" }) selected=\(browser.index(of: browser.selected) ?? -1) copy=\(browser.index(of: copy) ?? -1) second=\(browser.index(of: second) ?? -1)")
        key("T", modifiers: [.command, .shift])
        await expect("⇧⌘T reopens the tab just closed", { browser.tabs.count == 4 && browser.selected?.url == two && browser.selected !== second })
        await shown()
        guard let row = table.view(atColumn: 0, row: browser.index(of: first) ?? 0, makeIfNecessary: false) as? TabRow else {
            return check("each tab has a row", false)
        }
        middleClick(row)
        await expect("a middle click on a tab closes it", { !browser.tabs.contains { $0 === first } })
        await expect("…and its row goes", { table.numberOfRows == browser.tabs.count })
        key(",")
        key(",")
        await expect("⌘, twice shows the one Settings tab", { browser.tabs.filter { $0.page == .settings }.count == 1 && browser.selected?.page == .settings })
    }

    private func siteIcon() async {
        let tab = await open(server.url("/page/WebKit-Test-Page"))
        await expect("the tab shows the site's icon", { Favicons.shared.icon(for: tab.url) != nil })
        let file = Favicons.shared.file(for: "localhost")
        await expect("a site's icon is kept on disk while it's in History", { FileManager.default.fileExists(atPath: file.path) })
        History.shared.clear()
        check("clearing History deletes its icons", !FileManager.default.fileExists(atPath: file.path))
    }

    private func tabList() async {
        _ = await open(server.url("/page/one"))
        _ = await open(server.url("/page/two"))
        let table = shell.sidebar.tabList.table
        await expect("the tab list shows three rows", { table.numberOfRows == 3 })
        table.layoutSubtreeIfNeeded()
        let moving = browser.tabs[0], keep = browser.selected
        drag(table, rows: 2.2)
        check("dragging a tab moves it, keeping the selection", browser.tabs[2] === moving && browser.selected === keep,
              "index=\(browser.index(of: moving) ?? -1)")
        check("a dragged tab stays visible while it moves", ink(TabTable.lastLift) > 20, "ink=\(ink(TabTable.lastLift))")
        await shown()
        check("the rows are in the tabs' order after the drag", (0 ..< table.numberOfRows).allSatisfy { row in
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabRow)?.toolTip == browser.tabs[row].url?.absoluteString
        })
        browser.select(browser.tabs[0])
        key(SelfTest.upArrow, modifiers: [.command, .shift])
        check("⇧⌘↑ on the first tab goes to the last", browser.selected === browser.tabs.last)
        key(SelfTest.downArrow, modifiers: [.command, .shift])
        check("⇧⌘↓ on the last tab goes to the first", browser.selected === browser.tabs.first)
        Preferences.shared.settings.newTabPosition = .top
        let atTop = browser.newTab()
        Preferences.shared.settings.newTabPosition = .bottom
        let atBottom = browser.newTab()
        browser.select(browser.tabs[1])
        Preferences.shared.settings.newTabPosition = .below
        let below = browser.newTab()
        check("new tabs open at the top, the bottom, or below the current one",
              browser.tabs.first === atTop && browser.tabs.last === atBottom && browser.tabs[2] === below)
        await shown()
        check("…and the list has a row for each", table.numberOfRows == browser.tabs.count, "rows=\(table.numberOfRows)")
    }
}
#endif
