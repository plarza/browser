import AppKit
import BrowserKit

/// The tabs, down the left. No pinned tabs; a Persist tab is sky blue.
@MainActor
final class TabListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: (Tab) -> Void = { _ in }
    var onClose: (Tab) -> Void = { _ in }
    var onPersist: (Tab) -> Void = { _ in }
    var onMove: (Int, Int) -> Void = { _, _ in }
    var onDuplicate: (Tab) -> Void = { _ in }

    private let table = TabTable()
    private var tabs: [Tab] = []
    private weak var selected: Tab?

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
        table.onClick = { [weak self] row in
            guard let self, self.tabs.indices.contains(row) else { return }
            self.onSelect(self.tabs[row])
        }
        table.onMove = { [weak self] from, to in
            guard let self, self.tabs.indices.contains(from) else { return }
            self.tabs.insert(self.tabs.remove(at: from), at: to)
            // The window's own list takes "above this row" positions.
            self.onMove(from, to > from ? to + 1 : to)
        }
        table.menu = NSMenu()
        table.menu?.delegate = self
        documentView = table
        NotificationCenter.default.addObserver(forName: Favicons.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll(except: []) }
        }
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

    func reload(_ tabs: [Tab], selected: Tab?) {
        let old = self.tabs
        let previous = self.selected
        self.tabs = tabs
        self.selected = selected
        // One tab in or out: animate just that row; anything else redraws.
        let change = tabs.difference(from: old) { $0 === $1 }
        switch (change.insertions.first, change.removals.first, change.count) {
        case (.insert(let i, _, _)?, nil, 1):
            table.insertRows(at: [i], withAnimation: [.effectFade, .slideDown])
            refreshAll(except: [i])
        case (nil, .remove(let i, _, _)?, 1):
            table.removeRows(at: [i], withAnimation: [.effectFade, .slideUp])
            refreshAll(except: [])
        case (_, _, 0):
            if previous !== selected { refreshAll(except: []) }
        default:
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
        // Weakly: AppKit keeps cells for reuse, and a closed tab must go, jar and all.
        cell.onClose = { [weak self, weak tab] in if let tab { self?.onClose(tab) } }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// The tab list's table. Pressing a row selects it; dragging lifts the row
/// out to follow the pointer, held where it was grabbed, while the others
/// slide out of its way.
@MainActor
final class TabTable: NSTableView {
    var onClick: (Int) -> Void = { _ in }
    var onMove: (Int, Int) -> Void = { _, _ in }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        let grabbed = row(at: start)
        guard grabbed >= 0, let window else { return super.mouseDown(with: event) }
        var current = grabbed
        var lifted: NSImageView?
        let rowFrame = rect(ofRow: grabbed)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event, event.type == .leftMouseDragged else { stop.pointee = true; return }
            let point = self.convert(event.locationInWindow, from: nil)
            if lifted == nil {
                guard abs(point.y - start.y) > 3 else { return }
                lifted = self.lift(row: current, frame: rowFrame)
            }
            // The lifted row keeps the grab point under the pointer.
            let y = min(max(rowFrame.minY + point.y - start.y, -rowFrame.height / 2), self.bounds.height - rowFrame.height / 2)
            lifted?.frame.origin.y = y
            let target = min(max(Int((y + rowFrame.height / 2) / (self.rowHeight + self.intercellSpacing.height)), 0), self.numberOfRows - 1)
            if target != current {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    self.moveRow(at: current, to: target)
                }
                self.onMove(current, target)
                current = target
            }
        }
        if let lifted {
            // The row's own view, not its index: the list can change before
            // the animation ends (a tab closed), and the view goes with it.
            weak var hidden = view(atColumn: 0, row: current, makeIfNecessary: false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                lifted.animator().frame.origin.y = rect(ofRow: current).minY
            } completionHandler: {
                MainActor.assumeIsolated {
                    lifted.removeFromSuperview()
                    hidden?.alphaValue = 1
                }
            }
        } else {
            onClick(grabbed)
        }
    }

    /// A picture of the row, over the table; the row itself is left empty.
    private func lift(row: Int, frame: NSRect) -> NSImageView? {
        guard let cell = view(atColumn: 0, row: row, makeIfNecessary: false), let layer = cell.layer,
              let image = TabTable.picture(of: cell, layer: layer) else { return nil }
        let view = NSImageView(frame: frame)
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.shadowOpacity = 0.15
        view.layer?.shadowRadius = 6
        view.layer?.shadowOffset = NSSize(width: 0, height: -2)
        addSubview(view)
        #if DEBUG
        TabTable.lastLift = image
        #endif
        cell.alphaValue = 0
        return view
    }

    #if DEBUG
    static var lastLift: NSImage?
    #endif

    /// Drawn now, while the row is still showing: the row's layers
    /// (selection, Persist's blue, the icon and title) at screen scale.
    static func picture(of cell: NSView, layer: CALayer) -> NSImage? {
        let scale = cell.window?.backingScaleFactor ?? 2
        let size = cell.bounds.size
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        // A card under it, so the rows it passes over don't show through.
        cell.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.textBackgroundColor.cgColor)
        }
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        cell.displayIfNeeded()
        layer.render(in: context)
        guard let cg = context.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: size)
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
        for item in menu.items {
            item.target = self
            item.representedObject = tab
        }
    }

    @objc private func menuPersist(_ item: NSMenuItem) { (item.representedObject as? Tab).map(onPersist) }
    @objc private func menuDuplicate(_ item: NSMenuItem) { (item.representedObject as? Tab).map(onDuplicate) }
    @objc private func menuClose(_ item: NSMenuItem) { (item.representedObject as? Tab).map(onClose) }
}

@MainActor
final class TabCell: NSTableCellView {
    var onClose: () -> Void = {}
    private let label = NSTextField(labelWithString: "")
    private let tile = Monogram()
    private let spinner = NSProgressIndicator()
    private let close = NSButton()
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { close.isHidden = !hovering; needsDisplay = true } }
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
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Close Tab"
        close.target = self
        close.action = #selector(closeTab)
        close.isHidden = true
        for v in [tile, spinner, label, close] as [NSView] {
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
            label.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTab() { onClose() }

    func configure(_ tab: Tab, selected: Bool) {
        let title = tab.title.isEmpty ? (tab.url.map(AddressField.display) ?? "New Tab") : tab.title
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        tile.set(icon: Favicons.shared.icon(for: tab.url), popup: tab.opener != nil)
        if tab.isLoading { spinner.startAnimation(nil); tile.alphaValue = 0 } else { spinner.stopAnimation(nil); tile.alphaValue = 1 }
        isSelected = selected
        isPersist = tab.persist
        toolTip = tab.url?.absoluteString
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    /// A Persist tab is sky blue, lightening towards the bottom, and deeper
    /// when selected.
    private let sky = CAGradientLayer()

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = isPersist ? .clear
                : isSelected ? NSColor.labelColor.withAlphaComponent(0.07)
                : hovering ? NSColor.labelColor.withAlphaComponent(0.035) : NSColor.labelColor.withAlphaComponent(0)
            Motion.set(layer, "backgroundColor", fill.cgColor)
            if sky.superlayer == nil {
                sky.startPoint = CGPoint(x: 0.5, y: 1)
                sky.endPoint = CGPoint(x: 0.5, y: 0)
                sky.cornerRadius = 10
                sky.cornerCurve = .continuous
                layer?.insertSublayer(sky, at: 0)
            }
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let colors: [NSColor] = dark
                ? (isSelected ? [NSColor(red: 0.16, green: 0.30, blue: 0.50, alpha: 1), NSColor(red: 0.12, green: 0.25, blue: 0.44, alpha: 1)]
                              : [NSColor(red: 0.12, green: 0.22, blue: 0.36, alpha: 1), NSColor(red: 0.10, green: 0.19, blue: 0.32, alpha: 1)])
                : (isSelected ? [NSColor(red: 0.83, green: 0.91, blue: 1, alpha: 1), NSColor(red: 0.89, green: 0.94, blue: 1, alpha: 1)]
                              : [NSColor(red: 0.925, green: 0.962, blue: 1, alpha: 1), NSColor(red: 0.955, green: 0.977, blue: 1, alpha: 1)])
            Motion.set(sky, "colors", colors.map(\.cgColor), duration: 0.25)
            Motion.set(sky, "opacity", Float(isPersist ? 1 : 0), duration: 0.25)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.run { sky.frame = bounds }
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
