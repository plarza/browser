import AppKit
import BrowserKit

/// The pages under the address field as you type: icon, title, address.
/// ↑ and ↓ move through them, Return or a click opens one.
@MainActor
final class SuggestionList: NSView {
    var onPick: (History.Visit) -> Void = { _ in }
    private(set) var visits: [History.Visit] = []
    /// The list is up, or on its way; false as soon as it starts to go.
    private(set) var isShown = false
    private var index = -1
    private let stack = NSStackView()
    var selected: History.Visit? { visits.indices.contains(index) ? visits[index] : nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        shadow = NSShadow()
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -4)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        addPinned(stack)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func show(_ visits: [History.Visit]) {
        self.visits = visits
        index = -1
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (place, visit) in visits.enumerated() {
            let row = SuggestionRow(visit)
            row.onHover = { [weak self] in self?.select(place) }
            row.onClick = { [weak self] in self?.onPick(visit) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10).isActive = true
        }
        let show = !visits.isEmpty
        guard show != isShown else { return }
        isShown = show
        if show, isHidden {
            alphaValue = 0
            isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = show ? 1 : 0
        } completionHandler: {
            // Still wanted gone: typing on can bring it back before it fades.
            MainActor.assumeIsolated { if !self.isShown { self.isHidden = true } }
        }
    }

    func hide() { show([]) }

    /// ↑/↓: false when there is nothing to move through. It wraps, by way
    /// of what was typed: ↑ from there goes to the bottom of the list, ↓
    /// from the bottom comes back to it.
    func move(_ by: Int) -> Bool {
        guard isShown, !visits.isEmpty else { return false }
        let positions = visits.count + 1
        select((index + 1 + by + positions) % positions - 1)
        return true
    }

    private func select(_ place: Int) {
        index = place
        for (row, view) in stack.arrangedSubviews.enumerated() { (view as? SuggestionRow)?.isSelected = row == place }
    }
}

/// One line, the size of a tab: the icon, the page's title, then its
/// address in grey.
@MainActor
final class SuggestionRow: NSView {
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}
    var isSelected = false { didSet { needsDisplay = true } }

    init(_ visit: History.Visit) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        let icon = NSImageView(image: Favicons.shared.icon(for: URL(string: visit.url)) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!)
        icon.contentTintColor = .tertiaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .paragraphStyle: paragraph]
        let text = NSMutableAttributedString()
        if !visit.title.isEmpty {
            text.append(NSAttributedString(string: visit.title + "  ", attributes: base.merging([.foregroundColor: NSColor.labelColor]) { $1 }))
        }
        text.append(NSAttributedString(string: History.bare(visit.url), attributes: base.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }))
        let label = NSTextField(labelWithAttributedString: text)
        label.usesSingleLineMode = true
        label.cell?.wraps = false
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The same measures as a tab row's, so a suggestion lines up with a tab.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isSelected ? 0.07 : 0).cgColor
        }
    }

    override func mouseEntered(with event: NSEvent) { onHover() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick() }
}
