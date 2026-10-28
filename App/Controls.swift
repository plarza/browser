import AppKit
import CoreKit

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
        selectEverything()
        return true
    }

    /// A click or ⌘L: the whole address, https and all, selected.
    func focus() {
        beginEditing()
        if currentEditor() == nil { window?.makeFirstResponder(self) }
        selectEverything()
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
        show(url)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit(textView.string)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape()
            return true
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

    /// Fades in and out.
    func present() {
        guard isHidden else { return }
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 1
        }
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
