import AppKit
import BrowserKit

/// This session's downloads at the foot of the sidebar, in the tabs' own
/// row style, newest at the top; each row's background fills as it
/// downloads. Clicking a finished one shows it in Finder and takes it off;
/// it goes by itself after a minute.
@MainActor
final class DownloadRows: NSView {
    /// No more than this many at once; the rest are on about://downloads.
    static let limit = 3
    var onShowAll: () -> Void = {}
    private let stack = NSStackView()
    private var following: Observer?

    /// The rows showing, newest first.
    var rows: [DownloadRow] { stack.arrangedSubviews.compactMap { $0 as? DownloadRow } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.spacing = 3
        stack.alignment = .width
        addPinned(stack)
        following = Observer { [weak self] in self?.show(Array(Downloads.shared.recent.prefix(DownloadRows.limit))) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func show(_ items: [Downloads.Item]) {
        let old = rows
        for row in old where !items.contains(where: { $0 === row.item }) { row.removeFromSuperview() }
        for (place, item) in items.enumerated() {
            let row = old.first { $0.item === item } ?? DownloadRow(item) { [weak self] in self?.onShowAll() }
            if stack.arrangedSubviews.firstIndex(of: row) != place {
                row.removeFromSuperview()
                stack.insertArrangedSubview(row, at: place)
            }
        }
        isHidden = items.isEmpty
    }
}

/// One download, drawn like a tab: its total size on the right, an x to
/// cancel while hovering, and a minus to take it off once it's done.
@MainActor
final class DownloadRow: NSView {
    let item: Downloads.Item
    private let onShowAll: () -> Void
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let size = NSTextField(labelWithString: "")
    private let button = NSButton()
    private let fill = CAGradientLayer()
    private var following: Observer?
    var hovering = false { didSet { update() } }

    /// What the right-hand side shows.
    enum Accessory: Equatable {
        case size
        /// Cancels a download in progress.
        case cancel
        /// Takes a download that's over off the sidebar.
        case remove

        var symbol: String { self == .cancel ? "xmark" : "minus" }
        var label: String { self == .cancel ? "Cancel Download" : "Remove from Sidebar" }
    }

    var accessory: Accessory {
        if item.state != .active { return .remove }
        return hovering ? .cancel : .size
    }

    init(_ item: Downloads.Item, onShowAll: @escaping () -> Void) {
        self.item = item
        self.onShowAll = onShowAll
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
        for view in [icon, name, size, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
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
        following = Observer { [weak self] in self?.update() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        name.stringValue = item.name
        name.textColor = item.state == .failed || item.state == .cancelled ? .secondaryLabelColor : .labelColor
        let total = item.expected > 0 ? item.expected : item.received
        size.stringValue = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let accessory = accessory
        size.isHidden = accessory != .size
        button.isHidden = accessory == .size
        if accessory != .size {
            button.image = NSImage(systemSymbolName: accessory.symbol, accessibilityDescription: accessory.label)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            button.toolTip = accessory.label
        }
        toolTip = item.state == .finished ? "Show in Finder" : item.name
        // The progress is the row's background; a finished row is plain again.
        progress = item.state == .active ? (item.fraction ?? 0) : 0
        needsLayout = true
        needsDisplay = true
    }

    /// How much of the row is filled, 0 to 1.
    private var progress = 0.0

    /// The x or the minus.
    @objc func pressed() {
        if item.state == .active { Task { await Dialogs.cancelDownload(item) } } else { Downloads.shared.dismiss(item) }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovering ? 0.075 : 0.045).cgColor
            fill.colors = (isDark
                ? NSColor.sky(selected: true, dark: true)
                : [NSColor(red: 0.83, green: 0.91, blue: 1, alpha: 1), NSColor(red: 0.89, green: 0.94, blue: 1, alpha: 1)]).map(\.cgColor)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.run(duration: 0.2) { fill.frame = NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if contains(event), item.state == .finished { reveal() }
    }
}

/// Right-click on a download.
extension DownloadRow: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if item.state == .active {
            menu.addItem(withTitle: "Cancel Download", action: #selector(cancel), keyEquivalent: "")
        } else {
            if item.state == .finished {
                menu.addItem(withTitle: "Show in Finder", action: #selector(reveal), keyEquivalent: "")
            }
            menu.addItem(withTitle: "Remove from Sidebar", action: #selector(dismiss), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show All Downloads", action: #selector(showAll), keyEquivalent: "")
        for item in menu.items { item.target = self }
    }

    @objc private func cancel() { Task { await Dialogs.cancelDownload(item) } }
    @objc private func dismiss() { Downloads.shared.dismiss(item) }
    @objc private func showAll() { onShowAll() }

    /// Shown in Finder, and off the sidebar: it has been dealt with.
    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([item.file])
        Downloads.shared.dismiss(item)
    }
}
