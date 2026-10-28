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
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.drag])
        table.draggingDestinationFeedbackStyle = .gap
        table.menu = NSMenu()
        table.menu?.delegate = self
        documentView = table
        NotificationCenter.default.addObserver(forName: Favicons.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll(except: []) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(_ tabs: [Tab], selected: Tab?) {
        let old = self.tabs
        let previous = self.selected
        self.tabs = tabs
        self.selected = selected
        // One tab in or out: animate just that row; anything else redraws.
        if tabs.count == old.count + 1, let i = tabs.indices.first(where: { $0 >= old.count || tabs[$0] !== old[$0] }),
           Array(tabs[..<i]) == Array(old[..<i]), Array(tabs[(i + 1)...]) == Array(old[i...]) {
            table.insertRows(at: [i], withAnimation: [.effectFade, .slideDown])
            refreshAll(except: [i])
        } else if tabs.count + 1 == old.count, let i = old.indices.first(where: { $0 >= tabs.count || tabs[$0] !== old[$0] }),
                  Array(old[..<i]) == Array(tabs[..<i]), Array(old[(i + 1)...]) == Array(tabs[i...]) {
            table.removeRows(at: [i], withAnimation: [.effectFade, .slideUp])
            refreshAll(except: [])
        } else if tabs.count == old.count, zip(tabs, old).allSatisfy({ $0 === $1 }) {
            if previous !== selected { refreshAll(except: []) }
        } else {
            table.reloadData()
        }
        if let selected, let row = tabs.firstIndex(where: { $0 === selected }) { table.scrollRowToVisible(row) }
    }

    private func refreshAll(except skip: Set<Int>) {
        for (row, tab) in tabs.enumerated() where !skip.contains(row) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCell)?.configure(tab, selected: tab === selected)
        }
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
    private let tile = Monogram()
    private let spinner = NSProgressIndicator()
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { needsDisplay = true } }
    private var isSelected = false
    private var isPersist = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for v in [tile, spinner, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 18),
            tile.heightAnchor.constraint(equalToConstant: 18),
            spinner.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ tab: Tab, selected: Bool) {
        let title = tab.title.isEmpty ? (tab.url.map(AddressField.display) ?? "New Tab") : tab.title
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        tile.set(icon: Favicons.shared.icon(for: tab.url), popup: tab.opener != nil)
        if tab.isLoading { spinner.startAnimation(nil); tile.alphaValue = 0 } else { spinner.stopAnimation(nil); tile.alphaValue = 1 }
        isSelected = selected
        isPersist = tab.persist
        toolTip = tab.persist ? "Persist: reloads and navigation keep this tab's cookies and storage until it closes." : tab.url?.absoluteString
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let glow = NSColor.systemBlue
            let fill: NSColor = isPersist
                ? glow.withAlphaComponent(isSelected ? 0.16 : hovering ? 0.11 : 0.08)
                : isSelected ? NSColor.labelColor.withAlphaComponent(0.07)
                : hovering ? NSColor.labelColor.withAlphaComponent(0.035) : NSColor.labelColor.withAlphaComponent(0)
            Motion.set(layer, "backgroundColor", fill.cgColor)
            layer?.shadowColor = glow.cgColor
            layer?.shadowRadius = 8
            layer?.shadowOffset = .zero
            Motion.set(layer, "shadowOpacity", Float(isPersist ? 0.55 : 0), duration: 0.3)
            Motion.set(layer, "borderColor", glow.withAlphaComponent(isPersist ? 0.35 : 0).cgColor, duration: 0.3)
            layer?.borderWidth = 0.5
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose() } else { super.otherMouseUp(with: event) }
    }
}

/// The site's icon, faded in when it arrives; nothing until then, or when
/// a site has none.
@MainActor
final class Monogram: NSView {
    private let image = NSImageView()
    private let arrow = NSTextField(labelWithString: "↳")
    private var hasIcon = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 3
        image.layer?.masksToBounds = true
        arrow.font = .systemFont(ofSize: 11, weight: .semibold)
        arrow.textColor = .tertiaryLabelColor
        for v in [image, arrow] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            image.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            image.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            image.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            arrow.centerXAnchor.constraint(equalTo: centerXAnchor),
            arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A popup with no icon yet shows ↳, to say whose it is.
    func set(icon: NSImage?, popup: Bool) {
        let arriving = icon != nil && !hasIcon
        hasIcon = icon != nil
        image.image = icon
        arrow.isHidden = hasIcon || !popup
        if arriving {
            image.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                image.animator().alphaValue = 1
            }
        }
    }
}
