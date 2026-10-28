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

    private let field = NSTextField()
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
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isEditing ? 0.1 : 0.06).cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(isEditing ? 0.5 : 0).cgColor
            layer?.borderWidth = isEditing ? 1.5 : 0
        }
    }

    override func mouseDown(with event: NSEvent) { focus() }

    func focus() {
        window?.makeFirstResponder(field)
        beginEditing()
        field.currentEditor()?.selectAll(nil)
    }

    /// The page's address: the host while not editing, all of it when you click in.
    func show(_ url: URL?) {
        self.url = url
        guard !isEditing else { return }
        field.stringValue = url.map(Self.display) ?? ""
        field.alignment = url == nil ? .left : .center
        let secure = url?.scheme == "https"
        let symbol = url == nil ? "magnifyingglass" : secure ? "lock.fill" : "exclamationmark.triangle.fill"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = url != nil && !secure ? .systemOrange : .secondaryLabelColor
        reload.isHidden = url == nil
    }

    static func display(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private func beginEditing() {
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

/// Back and forward, and the sidebar toggle: glass buttons beside the
/// traffic lights.
@MainActor
final class NavigationButtons: NSStackView {
    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    var onSidebar: () -> Void = {}
    private let back = NavigationButtons.button("chevron.left", "Back")
    private let forward = NavigationButtons.button("chevron.right", "Forward")
    private let sidebar = NavigationButtons.button("sidebar.left", "Hide Sidebar")

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        back.target = self; back.action = #selector(goBack)
        forward.target = self; forward.action = #selector(goForward)
        sidebar.target = self; sidebar.action = #selector(toggle)
        addArrangedSubview(sidebar)
        addArrangedSubview(back)
        addArrangedSubview(forward)
        update(back: false, forward: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func button(_ symbol: String, _ label: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))!, target: nil, action: nil)
        b.bezelStyle = .glass
        b.controlSize = .regular
        b.toolTip = label
        return b
    }

    func update(back canBack: Bool, forward canForward: Bool) {
        back.isEnabled = canBack
        forward.isEnabled = canForward
    }

    @objc private func goBack() { onBack() }
    @objc private func goForward() { onForward() }
    @objc private func toggle() { onSidebar() }
}

/// The page, as a card with rounded corners and a soft shadow.
@MainActor
final class PageCard: NSView {
    let content = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            content.layer?.borderColor = NSColor.separatorColor.cgColor
        }
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
        self.value = value
        isHidden = value >= 1
        needsLayout = true
    }

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width * max(0.08, value), height: bounds.height)
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
