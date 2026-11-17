import AppKit
import BrowserKit

/// The tabs, down the left, in the browser's order. No pinned tabs; a
/// Persist tab is sky blue. Each row follows its own tab; the list follows
/// which tabs there are.
@MainActor
final class TabList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let table = TabTable()
    private let browser: Browser
    private var tabs: [Tab] = []
    private var following: Observer?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        table.addTableColumn(NSTableColumn(identifier: .init("tab")))
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.onClick = { [weak self] row in
            guard let self, tabs.indices.contains(row) else { return }
            browser.select(tabs[row])
        }
        table.onMove = { [weak self] from, to in
            guard let self, tabs.indices.contains(from) else { return }
            tabs.insert(tabs.remove(at: from), at: to)
            // The browser's own list takes "above this row" positions.
            browser.move(from: from, to: to > from ? to + 1 : to)
        }
        table.menu = NSMenu()
        table.menu?.delegate = self
        // Each item says for itself whether it applies.
        table.menu?.autoenablesItems = false
        documentView = table
        following = Observer { [weak self] in self?.show(browser.tabs, selected: browser.selected) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Tabs that fit don't scroll or bounce; only an overflowing list moves.
    private var overflows: Bool {
        table.bounds.height > contentView.bounds.height + 0.5
    }

    override func tile() {
        super.tile()
        verticalScrollElasticity = overflows ? .automatic : .none
    }

    override func scrollWheel(with event: NSEvent) {
        verticalScrollElasticity = overflows ? .automatic : .none
        if overflows || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    private func show(_ tabs: [Tab], selected: Tab?) {
        let old = self.tabs
        self.tabs = tabs
        // A tab in or out, or one closing as another opens: just those rows
        // move. Anything more (the tabs coming back at launch) redraws.
        let change = tabs.difference(from: old) { $0 === $1 }
        if old.isEmpty || change.count > 2 {
            table.reloadData()
        } else if !change.isEmpty {
            table.beginUpdates()
            for case .remove(let row, _, _) in change.removals.reversed() {
                table.removeRows(at: [row], withAnimation: [.effectFade, .slideUp])
            }
            for case .insert(let row, _, _) in change.insertions {
                table.insertRows(at: [row], withAnimation: [.effectFade, .slideDown])
            }
            table.endUpdates()
        }
        if let row = tabs.firstIndex(where: { $0 === selected }) { table.scrollRowToVisible(row) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("tab"), owner: nil) as? TabRow) ?? TabRow()
        cell.identifier = .init("tab")
        cell.show(tabs[row], in: browser)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// Right-click on a tab: Persist, Duplicate, Close.
extension TabList: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard tabs.indices.contains(table.clickedRow) else { return }
        let tab = tabs[table.clickedRow]
        let persist = NSMenuItem(title: "Persist Tab", action: #selector(persist(_:)), keyEquivalent: "i")
        persist.state = tab.persist ? .on : .off
        // A popup lives in its opener's jar; it has none of its own to keep.
        persist.isEnabled = !tab.isPopup
        menu.addItem(persist)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Duplicate Tab", action: #selector(duplicate(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Close Tab", action: #selector(close(_:)), keyEquivalent: ""))
        for item in menu.items {
            item.target = self
            item.representedObject = tab
        }
    }

    @objc private func persist(_ item: NSMenuItem) { (item.representedObject as? Tab)?.persist.toggle() }
    @objc private func duplicate(_ item: NSMenuItem) { (item.representedObject as? Tab).map(browser.duplicate) }
    @objc private func close(_ item: NSMenuItem) {
        guard let tab = item.representedObject as? Tab else { return }
        Task { await browser.closeAsking(tab) }
    }
}
