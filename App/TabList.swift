import AppKit
import CoreKit

/// The tabs, down the left. No pinned tabs; a Persist tab glows blue.
@MainActor
final class TabListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: (Tab) -> Void = { _ in }
    var onClose: (Tab) -> Void = { _ in }
    var onPersist: (Tab) -> Void = { _ in }
    var onMove: (Int, Int) -> Void = { _, _ in }
    var onDuplicate: (Tab) -> Void = { _ in }
    var onCloseOthers: (Tab) -> Void = { _ in }

    private let table = NSTableView()
    private var tabs: [Tab] = []
    private weak var selected: Tab?
    private static let drag = NSPasteboard.PasteboardType("net.aza.core.tab")

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        let column = NSTableColumn(identifier: .init("tab"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.drag])
        table.draggingDestinationFeedbackStyle = .gap
        table.menu = NSMenu()
        table.menu?.delegate = self
        documentView = table
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(_ tabs: [Tab], selected: Tab?) {
        self.tabs = tabs
        self.selected = selected
        table.reloadData()
        if let selected, let row = tabs.firstIndex(where: { $0 === selected }) { table.scrollRowToVisible(row) }
    }

    func refresh(_ tab: Tab) {
        guard let row = tabs.firstIndex(where: { $0 === tab }),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCell
        else { return }
        cell.configure(tab, selected: tab === selected)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tabs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? TabCell) ?? TabCell()
        cell.identifier = .init("cell")
        let tab = tabs[row]
        cell.configure(tab, selected: tab === selected)
        cell.onClose = { [weak self] in self?.onClose(tab) }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        onSelect(tabs[row])
        return false
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.drag)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        op == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.drag),
              let from = Int(text) else { return false }
        onMove(from, row)
        return true
    }
}

extension TabListView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard tabs.indices.contains(row) else { return }
        let tab = tabs[row]
        let persist = NSMenuItem(title: "Persist Tab", action: #selector(menuPersist(_:)), keyEquivalent: "i")
        persist.state = tab.persist ? .on : .off
        persist.isEnabled = tab.opener == nil
        menu.addItem(persist)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Duplicate Tab", action: #selector(menuDuplicate(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Close Tab", action: #selector(menuClose(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Close Other Tabs", action: #selector(menuCloseOthers(_:)), keyEquivalent: ""))
        for item in menu.items {
            item.target = self
            item.representedObject = tab
        }
    }

    @objc private func menuPersist(_ item: NSMenuItem) { (item.representedObject as? Tab).map(onPersist) }
    @objc private func menuDuplicate(_ item: NSMenuItem) { (item.representedObject as? Tab).map(onDuplicate) }
    @objc private func menuClose(_ item: NSMenuItem) { (item.representedObject as? Tab).map(onClose) }
    @objc private func menuCloseOthers(_ item: NSMenuItem) { (item.representedObject as? Tab).map(onCloseOthers) }
}

@MainActor
final class TabCell: NSTableCellView {
    var onClose: () -> Void = {}
    private let label = NSTextField(labelWithString: "")
    private let close = NSButton()
    private let spinner = NSProgressIndicator()
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { close.isHidden = !hovering } }
    private var isSelected = false
    private var isPersist = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        close.isBordered = false
        close.bezelStyle = .accessoryBarAction
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeClicked)
        close.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for v in [label, close, spinner] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -4),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18),
            close.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ tab: Tab, selected: Bool) {
        let title = tab.title.isEmpty ? (tab.url?.host ?? "New Tab") : tab.title
        label.stringValue = tab.opener != nil ? "↳ " + title : title
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        if tab.isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        isSelected = selected
        isPersist = tab.persist
        toolTip = tab.persist ? "Persist: reloads and navigation keep this tab's cookies and storage until it closes." : tab.url?.absoluteString
        needsDisplay = true
        updateLayer()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let base: NSColor = isSelected ? NSColor.labelColor.withAlphaComponent(0.1)
            : hovering ? NSColor.labelColor.withAlphaComponent(0.05) : .clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if isPersist {
                let glow = NSColor.systemBlue
                layer?.backgroundColor = glow.withAlphaComponent(isSelected ? 0.22 : 0.12).cgColor
                layer?.shadowColor = glow.cgColor
                layer?.shadowOpacity = 0.55
                layer?.shadowRadius = 6
                layer?.shadowOffset = .zero
                layer?.borderColor = glow.withAlphaComponent(0.35).cgColor
                layer?.borderWidth = 0.5
            } else {
                layer?.backgroundColor = base.cgColor
                layer?.shadowOpacity = 0
                layer?.borderWidth = 0
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateLayer() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateLayer() }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose() } else { super.otherMouseUp(with: event) }
    }

    @objc private func closeClicked() { onClose() }
}
