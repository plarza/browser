import AppKit
import BrowserKit

extension NSView {
    /// Adds `child` flush with all four edges, below `sibling` if given.
    func addPinned(_ child: NSView, below sibling: NSView? = nil) {
        child.translatesAutoresizingMaskIntoConstraints = false
        if let sibling { addSubview(child, positioned: .below, relativeTo: sibling) } else { addSubview(child) }
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// The one field: AppKit's search field, as Safari's is. It shows the host
/// while you're not editing, and the whole address, all selected, when you
/// click in or press ⌘L.
@MainActor
final class AddressField: NSSearchField, NSSearchFieldDelegate {
    var onSubmit: (String) -> Void = { _ in }
    var onEscape: () -> Void = {}
    private(set) var isEditing = false

    private var url: URL?
    private var flashing: DispatchWorkItem?
    /// Pages from history, under the field while typing. The window lays it out.
    let suggestions = SuggestionList()
    /// The last edit removed text: don't fill it straight back in.
    private var deleting = false
    private static let placeholder = "Search or enter website name"

    init() {
        super.init(frame: .zero)
        controlSize = .large
        font = .systemFont(ofSize: 13)
        placeholderString = Self.placeholder
        centersPlaceholder = true
        sendsWholeSearchString = true
        lineBreakMode = .byTruncatingTail
        delegate = self
        clear = (cell as? NSSearchFieldCell)?.cancelButtonCell
        suggestions.onPick = { [weak self] visit in
            self?.suggestions.hide()
            self?.onSubmit(visit.url)
        }
        show(nil)
    }

    /// The clear button, shown only while editing, as in Safari.
    private var clear: NSButtonCell?

    private func showClear(_ shown: Bool) {
        (cell as? NSSearchFieldCell)?.cancelButtonCell = shown ? clear : nil
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // The text goes in before focus does: changing a field's text while it
    // is being edited ends the editing.
    override func becomeFirstResponder() -> Bool {
        beginEditing()
        guard super.becomeFirstResponder() else { return false }
        quietEditor()
        selectEverything()
        return true
    }

    /// A click or ⌘L: the whole address, https and all, selected.
    func focus() {
        beginEditing()
        if currentEditor() == nil { window?.makeFirstResponder(self) }
        selectEverything()
    }

    /// The system's own grey word predictions would fight the fill-in.
    private func quietEditor() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.inlinePredictionType = .no
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
    }

    func selectEverything() {
        guard let editor = currentEditor() as? NSTextView else { return }
        if editor.string != stringValue { editor.string = stringValue }
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
    }

    func show(_ url: URL?) {
        self.url = url
        guard !isEditing else { return }
        stringValue = url.map(Self.display) ?? ""
        alignment = .center
        showClear(false)
    }

    static func display(_ url: URL) -> String {
        if url.scheme == "about" { return url.absoluteString }
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        alignment = .left
        showClear(true)
        stringValue = url?.absoluteString ?? ""
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditing = false
        suggestions.hide()
        show(url)
    }

    /// As you type: the rest of a site's name filled in and selected, so
    /// typing on replaces it and Delete removes it; and the best pages from
    /// history listed underneath.
    func controlTextDidChange(_ obj: Notification) {
        guard let editor = currentEditor() as? NSTextView else { return }
        let typed = editor.string
        let wasDeleting = deleting
        deleting = false
        suggestions.show(History.shared.suggest(typed))
        // After AppKit has finished with the keystroke: done here, the text
        // system puts the caret back after the typed character, and the
        // filled-in part ends up unselected.
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self, let editor, self.currentEditor() === editor, editor.string == typed, !wasDeleting,
                  editor.selectedRange() == NSRange(location: (typed as NSString).length, length: 0),
                  let fill = History.shared.autofill(typed), fill.lowercased().hasPrefix(typed.lowercased())
            else { return }
            let rest = String(fill.dropFirst(typed.count))
            let start = (typed as NSString).length
            editor.textStorage?.replaceCharacters(in: NSRange(location: start, length: 0), with: rest)
            editor.setSelectedRange(NSRange(location: start, length: (rest as NSString).length))
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = suggestions.selected?.url ?? textView.string
            suggestions.hide()
            onSubmit(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if suggestions.isShown { suggestions.hide() } else { onEscape() }
            return true
        case #selector(NSResponder.moveDown(_:)):
            return suggestions.move(1)
        case #selector(NSResponder.moveUp(_:)):
            return suggestions.move(-1)
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
             #selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteToBeginningOfLine(_:)):
            deleting = true
            return false
        default:
            return false
        }
    }

    func flash(_ message: String) {
        flashing?.cancel()
        let typed = stringValue
        stringValue = ""
        placeholderString = message
        focus()
        let restore = DispatchWorkItem { [weak self] in
            self?.placeholderString = Self.placeholder
            if self?.stringValue.isEmpty == true { self?.stringValue = typed }
        }
        flashing = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: restore)
    }
}

/// The pages under the address field as you type: icon, title, address.
/// ↑ and ↓ move through them, Return or a click opens one.
@MainActor
final class SuggestionList: NSView {
    var onPick: (History.Visit) -> Void = { _ in }
    private(set) var visits: [History.Visit] = []
    private var index = -1
    private let stack = NSStackView()
    var isShown: Bool { !isHidden }
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
        for (i, visit) in visits.enumerated() {
            let row = SuggestionRow(visit)
            row.onHover = { [weak self] in self?.select(i) }
            row.onClick = { [weak self] in self?.onPick(visit) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10).isActive = true
        }
        let show = !visits.isEmpty
        guard show == isHidden else { return }
        if show {
            alphaValue = 0
            isHidden = false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            if !show { self?.isHidden = true }
        }
    }

    func hide() { show([]) }

    /// ↑/↓: false when there is nothing to move through.
    func move(_ by: Int) -> Bool {
        guard isShown, !visits.isEmpty else { return false }
        select(min(max(index + by, -1), visits.count - 1))
        return true
    }

    private func select(_ i: Int) {
        index = i
        for (n, row) in stack.arrangedSubviews.enumerated() { (row as? SuggestionRow)?.isSelected = n == i }
    }
}

@MainActor
final class SuggestionRow: NSView {
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}
    var isSelected = false { didSet { needsDisplay = true } }

    init(_ visit: History.Visit) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        let icon = NSImageView(image: Favicons.shared.icon(for: URL(string: visit.url)) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)!)
        icon.contentTintColor = .tertiaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        let bare = History.bare(visit.url)
        let title = NSTextField(labelWithString: visit.title.isEmpty ? bare : visit.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        let address = NSTextField(labelWithString: bare)
        address.font = .systemFont(ofSize: 11)
        address.textColor = .secondaryLabelColor
        address.lineBreakMode = .byTruncatingTail
        for v in [icon, title, address] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            address.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            address.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            address.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
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

/// The sidebar and the page area: pure white (black in dark mode), flush
/// with each other with no line between them, or clear over the new tab
/// page's backdrop, which draws the glass (see `NewTabBackdrop.glassWidth`).
@MainActor
final class Surface: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    var isClear = false { didSet { if isClear != oldValue { needsDisplay = true } } }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isClear ? NSColor.clear.cgColor : NSColor.textBackgroundColor.cgColor
        }
    }
}

extension CATransaction {
    /// Layer changes made at once, or over `duration` when given.
    static func run(duration: CFTimeInterval? = nil, _ changes: () -> Void) {
        begin()
        if let duration { setAnimationDuration(duration) } else { setDisableActions(true) }
        changes()
        commit()
    }
}

/// What a blank tab shows behind nothing: the chosen picture filling the
/// page, a colour, or the desktop, frosted through the window. With Fill on
/// it spans the window, and the sidebar's part of it is glass: the picture
/// blurred and tinted with the sidebar's own colour (white, or black in dark
/// mode), by Settings' amounts.
@MainActor
final class NewTabBackdrop: NSView {
    private let picture = CALayer()
    private let frost = NSVisualEffectView()
    private let glass = NSView()
    private let blurred = CALayer()
    private let tint = CALayer()
    private var shownImage: URL?
    private var shownVersion = -1
    private var settings = Settings()
    /// The blur last asked for, and whether one is being made. One at a time,
    /// always of the latest ask, so dragging the slider never queues work.
    private var wantedBlur: (image: URL, version: Int, radius: Double)?
    private var shownBlur: (image: URL, version: Int, radius: Double)?
    private var blurring = false
    /// The picture decoded at blur size, kept while it stays the same.
    private var source: (image: URL, version: Int, cg: CGImage)?

    /// How much of the left edge is under the sidebar; 0 without Fill.
    var glassWidth: CGFloat = 0 { didSet { if glassWidth != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        layer?.addSublayer(picture)
        frost.material = .underWindowBackground
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.autoresizingMask = [.width, .height]
        addSubview(frost)
        glass.wantsLayer = true
        glass.layer?.masksToBounds = true
        blurred.contentsGravity = .resizeAspectFill
        glass.layer?.addSublayer(blurred)
        glass.layer?.addSublayer(tint)
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ settings: Settings, imageVersion: Int) {
        self.settings = settings
        frost.isHidden = settings.newTabPage != .blank
        picture.isHidden = settings.newTabPage != .image
        layer?.backgroundColor = settings.newTabPage == .color ? NSColor(hex: settings.newTabColor).cgColor : NSColor.clear.cgColor
        let image = Settings.newTabImageInUse
        if settings.newTabPage == .image, image != shownImage || imageVersion != shownVersion {
            shownImage = image
            shownVersion = imageVersion
            picture.contents = image.flatMap(NSImage.init(contentsOf:))
        }
        updateTint()
        blurred.isHidden = settings.newTabPage != .image
        if settings.newTabPage == .image, settings.fill, let image {
            // Up to 50 points of blur at the far end.
            wantedBlur = (image, imageVersion, settings.fillBlur * 50 / Settings.fillMax)
            blurNext()
        }
        needsLayout = true
    }

    private func blurNext() {
        guard !blurring, let wanted = wantedBlur else { return }
        wantedBlur = nil
        if let shown = shownBlur, shown == wanted { return }
        blurring = true
        let decoded = source.flatMap { $0.image == wanted.image && $0.version == wanted.version ? $0.cg : nil }
        Task.detached(priority: .userInitiated) {
            let picture = decoded ?? NewTabBackdrop.decode(wanted.image)
            let cg = picture.flatMap { NewTabBackdrop.blur($0, radius: wanted.radius) }
            await MainActor.run {
                if let picture { self.source = (wanted.image, wanted.version, picture) }
                self.blurred.contents = cg
                self.shownBlur = wanted
                self.blurring = false
                self.blurNext()
            }
        }
    }

    /// The sidebar's colour over the glass: none at full transparency,
    /// nearly opaque at none.
    private func updateTint() {
        let alpha = 0.92 * (1 - settings.fillTransparency / Settings.fillMax)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(alpha).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    nonisolated private static let context = CIContext()

    /// The picture at 1600 points wide at most.
    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let image = CIImage(contentsOf: url) else { return nil }
        let scale = min(1, 1600 / image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }

    /// Blurred with its edges held.
    nonisolated static func blur(_ picture: CGImage, radius: Double) -> CGImage? {
        let image = CIImage(cgImage: picture)
        guard radius > 0 else { return picture }
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
        return context.createCGImage(blurred, from: image.extent)
    }

    override func layout() {
        super.layout()
        CATransaction.run {
            picture.frame = bounds
            frost.frame = bounds
            glass.isHidden = glassWidth <= 0
            glass.frame = NSRect(x: 0, y: 0, width: glassWidth, height: bounds.height)
            // The blurred copy lies exactly over the picture, cut to the sidebar.
            blurred.frame = bounds
            tint.frame = glass.bounds
        }
    }
}

extension NSColor {
    /// "#RRGGBB"; anything else is black.
    convenience init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// The sidebar's shadow along the page's left edge, so the sidebar reads
/// as lying on top of the page: wide and faint. Clicks go through it.
@MainActor
final class SidebarShadow: NSView {
    private let gradient = CAGradientLayer()
    private static let width: CGFloat = 18

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.colors = [0.035, 0.014, 0].map { NSColor.black.withAlphaComponent($0).cgColor }
        gradient.locations = [0, 0.35, 1]
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.run { gradient.frame = NSRect(x: 0, y: 0, width: Self.width, height: bounds.height) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The sidebar's edge: drag to resize.
@MainActor
final class SidebarDivider: NSView {
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}

    override func resetCursorRects() { addCursorRect(bounds, cursor: .columnResize) }

    override func mouseDown(with event: NSEvent) {
        var last = event.locationInWindow.x
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { stop.pointee = true; return }
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.onEnd()
                return
            }
            let x = event.locationInWindow.x
            self.onDrag(x - last)
            last = x
        }
    }
}

/// Animates a layer property from its current value, the way a view's own
/// animator would: short and eased.
@MainActor
enum Motion {
    static let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    static func set(_ layer: CALayer?, _ key: String, _ value: Any?, duration: CFTimeInterval = 0.18) {
        guard let layer else { return }
        let from = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        layer.setValue(value, forKeyPath: key)
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = ease
        layer.add(animation, forKey: key)
    }
}

/// A two-point line across the top of the page while it loads.
@MainActor
final class ProgressLine: NSView {
    private let bar = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bar.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(bar)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var value = 1.0

    func set(_ value: Double) {
        let done = value >= 1
        if !done && self.value >= 1 {
            // A new load: start from nothing, without animating back.
            CATransaction.run { bar.frame.size.width = 0 }
        }
        self.value = value
        NSAnimationContext.runAnimationGroup { context in
            context.duration = done ? 0.35 : 0.2
            animator().alphaValue = done ? 0 : 1
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(Motion.ease)
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width * max(0.06, value), height: bounds.height)
        CATransaction.commit()
    }
}

/// ⌘F, as in Chrome: a field, "3/12", previous and next, close. Every
/// match on the page is highlighted by WebKit's find engine.
@MainActor
final class FindBar: NSGlassEffectView, NSSearchFieldDelegate {
    var onSearch: (String, Bool) -> Void = { _, _ in }
    var onClose: () -> Void = {}
    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let previous = FindBar.button("chevron.up", "Previous Match")
    private let next = FindBar.button("chevron.down", "Next Match")
    private let close = FindBar.button("xmark", "Close")
    var text: String { field.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = 20
        let body = NSView()
        contentView = body
        field.placeholderString = "Find on page"
        field.sendsSearchStringImmediately = true
        field.controlSize = .large
        field.delegate = self
        field.target = self
        field.action = #selector(changed)
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        previous.target = self; previous.action = #selector(goPrevious)
        next.target = self; next.action = #selector(goNext)
        close.target = self; close.action = #selector(closeClicked)
        let row = NSStackView(views: [field, count, previous, next, close])
        row.spacing = 4
        row.setCustomSpacing(8, after: count)
        row.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: body.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -6),
            field.widthAnchor.constraint(equalToConstant: 220),
            count.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    static func button(_ symbol: String, _ label: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        b.isBordered = false
        b.bezelStyle = .accessoryBarAction
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = label
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func present() { isHidden = false }
    func dismiss() { isHidden = true }

    /// "3/12", or "0/0" in red when nothing matches.
    func show(matches: Int, current: Int?) {
        guard !field.stringValue.isEmpty else { count.stringValue = ""; return }
        count.stringValue = matches == 0 ? "0/0" : "\((current ?? 0) + 1)/\(matches)"
        count.textColor = matches == 0 ? .systemRed : .secondaryLabelColor
        previous.isEnabled = matches > 0
        next.isEnabled = matches > 0
    }

    @objc private func changed() { onSearch(field.stringValue, false) }
    @objc private func goPrevious() { onSearch(field.stringValue, true) }
    @objc private func goNext() { onSearch(field.stringValue, false) }
    @objc private func closeClicked() { onClose() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSearch(field.stringValue, NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose()
            return true
        default:
            return false
        }
    }
}

/// Every dialog in Browser, as a sheet on the window: Return answers yes,
/// Escape answers no (or dismisses an alert that has only OK).
@MainActor
enum Dialogs {
    static func ask(in window: NSWindow? = NSApp.keyWindow, _ message: String, detail: String = "", yes: String, no: String? = "Cancel",
                    field: NSTextField? = nil) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: yes)
        if let no { alert.addButton(withTitle: no).keyEquivalent = "\u{1b}" }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // AppKit gives an OK-only alert no Escape: an unseen button that presses OK.
        if no == nil {
            let escape = NSButton(title: "", target: alert.buttons[0], action: #selector(NSButton.performClick(_:)))
            escape.keyEquivalent = "\u{1b}"
            escape.frame = .zero
            alert.accessoryView = NSView(frame: .zero)
            alert.accessoryView?.addSubview(escape)
        }
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    /// Cancelling deletes what's been downloaded so far, so it asks first.
    static func cancelDownload(_ item: Downloads.Item, in window: NSWindow? = NSApp.keyWindow) async {
        guard item.state == .active,
              await ask(in: window, "Cancel “\(item.name)”?", yes: "Cancel Download", no: "Keep Downloading"),
              item.state == .active else { return }
        Downloads.shared.cancel(item)
    }

    static func prompt(in window: NSWindow?, _ message: String, detail: String, text: String) async -> String? {
        let field = NSTextField(string: text)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        return await ask(in: window, message, detail: detail, yes: "OK", no: "Cancel", field: field) ? field.stringValue : nil
    }
}
