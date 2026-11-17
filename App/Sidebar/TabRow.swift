import AppKit
import BrowserKit

/// One tab in the list: its site's icon (a spinner while it loads), its
/// title, and an ✕ while the pointer is over it. The selected tab is
/// tinted; a Persist tab is sky blue. Middle-click closes it.
@MainActor
final class TabRow: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = TabIcon()
    private let spinner = NSProgressIndicator()
    private let close = NSButton()
    /// A Persist tab is sky blue, lightening towards the bottom, and deeper
    /// when selected.
    private let sky = CAGradientLayer()
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { close.isHidden = !hovering; needsDisplay = true } }
    private var isSelected = false
    private var isPersist = false

    // Weakly: AppKit keeps rows for reuse, and a closed tab must go, jar and all.
    private weak var tab: Tab?
    private weak var browser: Browser?
    private var following: Observer?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        sky.startPoint = CGPoint(x: 0.5, y: 1)
        sky.endPoint = CGPoint(x: 0.5, y: 0)
        sky.cornerRadius = 10
        sky.cornerCurve = .continuous
        sky.opacity = 0
        layer?.addSublayer(sky)
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
        for view in [icon, spinner, label, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The row is `tab`'s from now on, and keeps up with it.
    func show(_ tab: Tab, in browser: Browser) {
        self.tab = tab
        self.browser = browser
        following?.cancel()
        following = Observer { [weak self, weak tab, weak browser] in
            guard let self, let tab else { return }
            update(tab, selected: browser?.selected === tab)
        }
    }

    private func update(_ tab: Tab, selected: Bool) {
        label.stringValue = tab.title.isEmpty ? (tab.url.map(AddressField.display) ?? "New Tab") : tab.title
        label.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        label.textColor = selected ? .labelColor : .secondaryLabelColor
        icon.set(Favicons.shared.icon(for: tab.url), popup: tab.isPopup)
        if tab.isLoading {
            spinner.startAnimation(nil)
            icon.alphaValue = 0
        } else {
            spinner.stopAnimation(nil)
            icon.alphaValue = 1
        }
        isSelected = selected
        isPersist = tab.persist
        toolTip = tab.url?.absoluteString
        needsDisplay = true
    }

    /// A person closing the tab: a Persist tab asks first.
    @objc private func closeTab() {
        guard let tab, let browser else { return }
        Task { await browser.closeAsking(tab) }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = isPersist ? .clear
                : isSelected ? NSColor.labelColor.withAlphaComponent(0.07)
                : hovering ? NSColor.labelColor.withAlphaComponent(0.035) : NSColor.labelColor.withAlphaComponent(0)
            Motion.set(layer, "backgroundColor", fill.cgColor)
            Motion.set(sky, "colors", NSColor.sky(selected: isSelected, dark: isDark).map(\.cgColor), duration: 0.25)
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

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { closeTab() } else { super.otherMouseUp(with: event) }
    }
}

/// The site's icon, faded in when it arrives; nothing until then, or when
/// a site has none.
@MainActor
final class TabIcon: NSView {
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
        for view in [image, arrow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
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
    func set(_ icon: NSImage?, popup: Bool) {
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
