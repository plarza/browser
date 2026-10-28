import AppKit
import CoreKit

/// This session's downloads at the foot of the sidebar, in the tabs' own
/// row style, newest at the top; each row's background fills as it
/// downloads. Clicking a finished one shows it in Finder and takes it off.
@MainActor
final class DownloadDock: NSView {
    /// The styles to choose between; one stays.
    enum Style: String { case plain, percent, twoLine }
    static var style: Style { Style(rawValue: UserDefaults.standard.string(forKey: "downloadStyle") ?? "") ?? .percent }

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
                let row = DownloadTile(item: item, style: DownloadDock.style)
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

/// One download, drawn like a tab.
@MainActor
final class DownloadTile: NSView {
    let item: Downloads.Item
    let style: DownloadDock.Style
    var onShowAll: () -> Void = {}
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let fill = CAGradientLayer()
    private var hovering = false { didSet { needsDisplay = true } }

    init(item: Downloads.Item, style: DownloadDock.Style) {
        self.item = item
        self.style = style
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
        detail.font = .monospacedDigitSystemFont(ofSize: style == .twoLine ? 11 : 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.alignment = style == .twoLine ? .left : .right
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [icon, name, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        var constraints = [
            heightAnchor.constraint(equalToConstant: style == .twoLine ? 42 : 34),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: style == .twoLine ? 24 : 18),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
        ]
        switch style {
        case .plain:
            detail.isHidden = true
            constraints += [name.centerYAnchor.constraint(equalTo: centerYAnchor),
                            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)]
        case .percent:
            constraints += [name.centerYAnchor.constraint(equalTo: centerYAnchor),
                            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
                            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
                            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)]
        case .twoLine:
            constraints += [name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
                            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
                            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
                            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)]
        }
        NSLayoutConstraint.activate(constraints)
        menu = NSMenu()
        menu?.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        name.stringValue = item.name
        name.textColor = item.state == .failed ? .secondaryLabelColor : .labelColor
        let size = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        switch (style, item.state) {
        case (_, .failed): detail.stringValue = "Stopped"
        case (.twoLine, .active): detail.stringValue = item.expected > 0 ? "\(size(item.received)) of \(size(item.expected))" : size(item.received)
        case (_, .active): detail.stringValue = item.fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? size(item.received)
        case (.twoLine, .finished): detail.stringValue = "\(size(item.received)) · Show in Finder"
        case (_, .finished): detail.stringValue = size(item.received)
        }
        toolTip = item.state == .finished ? "Show in Finder" : item.name
        needsLayout = true
        needsDisplay = true
    }

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
        switch item.state {
        case .finished:
            NSWorkspace.shared.activateFileViewerSelecting([item.file])
            Downloads.shared.dismiss(item)
        case .failed:
            Downloads.shared.dismiss(item)
        case .active:
            break
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
