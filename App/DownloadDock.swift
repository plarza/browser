import AppKit
import AzoteKit

/// This session's downloads at the foot of the sidebar, in the tabs' own
/// row style, newest at the top; each row's background fills as it
/// downloads. Clicking a finished one shows it in Finder and takes it off;
/// it goes by itself after a minute.
@MainActor
final class DownloadDock: NSView {
    static let limit = 3
    private let stack = NSStackView()
    private var rows: [ObjectIdentifier: DownloadTile] = [:]
    var onShowAll: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.spacing = 3
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        NotificationCenter.default.addObserver(forName: Downloads.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        let items = Array(Downloads.shared.recent.prefix(DownloadDock.limit))
        let keep = Set(items.map(ObjectIdentifier.init))
        for (key, row) in rows where !keep.contains(key) {
            row.removeFromSuperview()
            rows[key] = nil
        }
        for (i, item) in items.enumerated() {
            let key = ObjectIdentifier(item)
            let row = rows[key] ?? {
                let row = DownloadTile(item: item)
                row.onShowAll = { [weak self] in self?.onShowAll() }
                rows[key] = row
                return row
            }()
            if stack.arrangedSubviews.firstIndex(of: row) != i {
                row.removeFromSuperview()
                stack.insertArrangedSubview(row, at: i)
            }
            row.refresh()
        }
        isHidden = items.isEmpty
    }
}


/// One download, drawn like a tab: its total size on the right, an x to
/// cancel while hovering, and a minus to take it off once it's done.
@MainActor
final class DownloadTile: NSView {
    let item: Downloads.Item
    var onShowAll: () -> Void = {}
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    private let button = NSButton()
    private let fill = CAGradientLayer()
    private var hovering = false { didSet { refresh() } }

    init(item: Downloads.Item) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        fill.startPoint = CGPoint(x: 0.5, y: 1)
        fill.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(fill)
        icon.image = NSWorkspace.shared.icon(for: .init(filenameExtension: item.file.pathExtension) ?? .data)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        size.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        size.textColor = .secondaryLabelColor
        size.alignment = .right
        size.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(pressed)
        for v in [icon, name, size, button] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            size.centerYAnchor.constraint(equalTo: centerYAnchor),
            size.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            size.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 22),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
        ])
        menu = NSMenu()
        menu?.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// What the right-hand side shows now: the size, an x, or a minus.
    var accessory: String {
        if item.state != .active { return "minus" }
        return hovering ? "xmark" : "size"
    }

    func refresh() {
        name.stringValue = item.name
        name.textColor = item.state == .failed ? .secondaryLabelColor : .labelColor
        let total = item.expected > 0 ? item.expected : item.received
        size.stringValue = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let symbol = accessory
        size.isHidden = symbol != "size"
        button.isHidden = symbol == "size"
        if symbol != "size" {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "xmark" ? "Cancel Download" : "Remove from Sidebar")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            button.toolTip = symbol == "xmark" ? "Cancel Download" : "Remove from Sidebar"
        }
        toolTip = item.state == .finished ? "Show in Finder" : item.name
        needsLayout = true
        needsDisplay = true
    }

    @objc private func pressed() {
        if item.state == .active { Downloads.shared.cancel(item) } else { Downloads.shared.dismiss(item) }
    }

    #if DEBUG
    func hoverForTesting(_ on: Bool) { hovering = on }
    func pressForTesting() { pressed() }
    #endif

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovering ? 0.075 : 0.045).cgColor
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            fill.colors = (dark
                ? [NSColor(red: 0.16, green: 0.30, blue: 0.50, alpha: 1), NSColor(red: 0.12, green: 0.25, blue: 0.44, alpha: 1)]
                : [NSColor(red: 0.83, green: 0.91, blue: 1, alpha: 1), NSColor(red: 0.89, green: 0.94, blue: 1, alpha: 1)]).map(\.cgColor)
        }
    }

    override func layout() {
        super.layout()
        // The progress is the row's background; a finished row is plain again.
        let fraction = item.state == .active ? (item.fraction ?? 0) : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if item.state == .finished {
            NSWorkspace.shared.activateFileViewerSelecting([item.file])
            Downloads.shared.dismiss(item)
        }
    }

    override func mouseDown(with event: NSEvent) {}
}

extension DownloadTile: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if item.state == .active {
            menu.addItem(withTitle: "Cancel Download", action: #selector(cancel), keyEquivalent: "").target = self
        } else {
            if item.state == .finished {
                menu.addItem(withTitle: "Show in Finder", action: #selector(reveal), keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: "Remove from Sidebar", action: #selector(dismiss), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show All Downloads", action: #selector(showAll), keyEquivalent: "").target = self
    }

    @objc private func cancel() { Downloads.shared.cancel(item) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([item.file]); Downloads.shared.dismiss(item) }
    @objc private func dismiss() { Downloads.shared.dismiss(item) }
    @objc private func showAll() { onShowAll() }
}
