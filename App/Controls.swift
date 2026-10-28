import AppKit
import CoreKit

/// The one field. Finishes addresses from history inline, as you type.
@MainActor
final class AddressField: NSTextField, NSTextFieldDelegate {
    var onSubmit: (String) -> Void = { _ in }
    var onEscape: () -> Void = {}
    private(set) var isEditing = false
    private var completing = false
    private var flashing: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        placeholderString = "Search or enter address"
        font = .systemFont(ofSize: 13)
        bezelStyle = .roundedBezel
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool {
        isEditing = true
        return super.becomeFirstResponder()
    }

    func controlTextDidEndEditing(_ obj: Notification) { isEditing = false }

    func controlTextDidChange(_ obj: Notification) {
        guard !completing, let editor = currentEditor() as? NSTextView else { return }
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
        let typed = stringValue
        stringValue = ""
        placeholderString = message
        window?.makeFirstResponder(self)
        let restore = DispatchWorkItem { [weak self] in
            self?.placeholderString = "Search or enter address"
            if self?.stringValue.isEmpty == true { self?.stringValue = typed }
        }
        flashing = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: restore)
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
final class FindBar: NSVisualEffectView, NSSearchFieldDelegate {
    var onSearch: (String, Bool) -> Void = { _, _ in }
    var onClose: () -> Void = {}
    private let field = NSSearchField()
    var text: String { field.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        field.placeholderString = "Find on page"
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.target = self
        field.action = #selector(changed)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
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
