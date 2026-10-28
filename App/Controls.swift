import AppKit
import CoreKit

/// The one field, as a capsule: a lock or a magnifying glass, the address
/// (just the host while you're not editing, as Safari shows it), and reload.
@MainActor
final class AddressField: NSView, NSTextFieldDelegate {
    var onSubmit: (String) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onReload: () -> Void = {}
    private(set) var isEditing = false
    var loading = false { didSet { if loading != oldValue { updateReload() } } }

    private let field = SelectingField()
    private let icon = NSImageView()
    private let reload = NSButton()
    private var url: URL?
    private var completing = false
    private var flashing: DispatchWorkItem?
    private static let placeholder = "Search or enter address"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.cornerCurve = .continuous

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = Self.placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.onBecome = { [weak self] in self?.beginEditing() }

        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)

        reload.isBordered = false
        reload.bezelStyle = .accessoryBarAction
        reload.contentTintColor = .secondaryLabelColor
        reload.target = self
        reload.action = #selector(reloadClicked)
        updateReload()

        for v in [icon, field, reload] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: reload.leadingAnchor, constant: -4),
            reload.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            reload.centerYAnchor.constraint(equalTo: centerYAnchor),
            reload.widthAnchor.constraint(equalToConstant: 20),
        ])
        show(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Motion.set(layer, "backgroundColor", NSColor.labelColor.withAlphaComponent(isEditing ? 0.04 : 0.05).cgColor)
            Motion.set(layer, "borderColor", NSColor.controlAccentColor.withAlphaComponent(isEditing ? 0.55 : 0).cgColor)
            layer?.borderWidth = 1.5
        }
    }

    override func mouseDown(with event: NSEvent) { focus() }

    /// A click or ⌘L: the whole address, https and all, selected.
    func focus() {
        // The text goes in before focus does: changing a field's text while
        // it is being edited ends the editing.
        beginEditing()
        if field.currentEditor() == nil { window?.makeFirstResponder(field) }
        field.selectEverything()
    }

    /// The page's address: the host while not editing, all of it when you click in.
    func show(_ url: URL?) {
        self.url = url
        guard !isEditing else { return }
        field.stringValue = url.map(Self.display) ?? ""
        field.alignment = url == nil ? .left : .center
        // Core's own pages (about://history) are neither secure nor not.
        let own = url?.scheme == "about"
        let secure = url?.scheme == "https"
        let symbol = url == nil ? "magnifyingglass" : own ? "clock" : secure ? "lock.fill" : "exclamationmark.triangle.fill"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = url != nil && !secure && !own ? .systemOrange : .secondaryLabelColor
        reload.isHidden = url == nil
    }

    static func display(_ url: URL) -> String {
        if url.scheme == "about" { return url.absoluteString }
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    fileprivate func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        field.alignment = .left
        field.stringValue = url?.absoluteString ?? ""
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        needsDisplay = true
    }

    func controlTextDidBeginEditing(_ obj: Notification) { beginEditing() }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditing = false
        needsDisplay = true
        show(url)
    }

    private func updateReload() {
        reload.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    }

    @objc private func reloadClicked() { onReload() }

    func controlTextDidChange(_ obj: Notification) {
        guard !completing, let editor = field.currentEditor() as? NSTextView else { return }
        let typed = editor.string
        // Only when the caret is at the end and the person is adding text.
        guard editor.selectedRange().location == (typed as NSString).length,
              let match = History.shared.complete(typed), match.count > typed.count
        else { return }
        completing = true
        let rest = String(match.dropFirst(typed.count))
        editor.string = typed + rest
        editor.setSelectedRange(NSRange(location: (typed as NSString).length, length: (rest as NSString).length))
        completing = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit(textView.string)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape()
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            // Delete the suggested part, not a character of what was typed.
            let range = textView.selectedRange()
            if range.length > 0, range.location + range.length == (textView.string as NSString).length {
                completing = true
                textView.string = (textView.string as NSString).substring(to: range.location)
                completing = false
                return true
            }
            return false
        default:
            return false
        }
    }

    func flash(_ message: String) {
        flashing?.cancel()
        let typed = field.stringValue
        field.stringValue = ""
        field.placeholderString = message
        focus()
        let restore = DispatchWorkItem { [weak self] in
            self?.field.placeholderString = Self.placeholder
            if self?.field.stringValue.isEmpty == true { self?.field.stringValue = typed }
        }
        flashing = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: restore)
    }
}

/// Pure white (black in dark mode), flush with the page, with no line
/// between them.
@MainActor
final class Sidebar: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    // The window drags from the sidebar's empty top, around the traffic lights.
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Where the page goes. Switching tabs cross-fades.
@MainActor
final class PageArea: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    func crossfade() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: "crossfade")
    }
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

/// The address text. Focused by any means, it holds the whole address with
/// all of it selected; the window turns a first click into a focus (see
/// BrowserWindowController.watchClicks) so no caret lands where it was clicked.
@MainActor
final class SelectingField: NSTextField {
    var onBecome: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        onBecome()
        guard super.becomeFirstResponder() else { return false }
        selectEverything()
        return true
    }

    /// The editor's text is the field's, all of it selected.
    func selectEverything() {
        guard let editor = currentEditor() as? NSTextView else { return }
        if editor.string != stringValue { editor.string = stringValue }
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bar.frame.size.width = 0
            CATransaction.commit()
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

/// ⌘F: a small field over the top right of the page.
@MainActor
final class FindBar: NSGlassEffectView, NSSearchFieldDelegate {
    var onSearch: (String, Bool) -> Void = { _, _ in }
    var onClose: () -> Void = {}
    private let field = NSSearchField()
    var text: String { field.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = 18
        let body = NSView()
        contentView = body
        field.placeholderString = "Find on page"
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.target = self
        field.action = #selector(changed)
        field.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -10),
            field.topAnchor.constraint(equalTo: body.topAnchor, constant: 7),
            field.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -7),
            field.widthAnchor.constraint(equalToConstant: 240),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// In from above with a fade; out the same way.
    func present() {
        guard isHidden else { return }
        isHidden = false
        alphaValue = 0
        layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: 8))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = Motion.ease
            animator().alphaValue = 1
        }
        Motion.set(layer, "transform", CATransform3DIdentity, duration: 0.24)
    }

    func dismiss() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.isHidden = true
        }
    }

    func matched(_ found: Bool) {
        field.textColor = found || field.stringValue.isEmpty ? .labelColor : .systemRed
    }

    @objc private func changed() { onSearch(field.stringValue, false) }

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

@MainActor
enum Dialogs {
    static func ask(in window: NSWindow?, _ message: String, detail: String, yes: String, no: String?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: yes)
        if let no { alert.addButton(withTitle: no) }
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    static func prompt(in window: NSWindow?, _ message: String, detail: String, text: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: text)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response: NSApplication.ModalResponse
        if let window { response = await alert.beginSheetModal(for: window) } else { response = alert.runModal() }
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
