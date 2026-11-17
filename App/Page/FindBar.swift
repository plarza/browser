import AppKit
import BrowserKit

/// ⌘F, as in Chrome: a field, "3/12", previous and next, close. Every
/// match on the page is highlighted by WebKit's find engine.
@MainActor
final class FindBar: NSGlassEffectView, NSSearchFieldDelegate {
    /// Escape, or the ✕.
    var onClose: () -> Void = {}
    private let browser: Browser
    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let previous = FindBar.button("chevron.up", "Previous Match")
    private let next = FindBar.button("chevron.down", "Next Match")
    private let close = FindBar.button("xmark", "Close")
    private var following: Observer?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        cornerRadius = 20
        let body = NSView()
        contentView = body
        field.placeholderString = "Find on page"
        field.sendsSearchStringImmediately = true
        field.controlSize = .large
        field.delegate = self
        field.target = self
        field.action = #selector(findNext)
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        previous.target = self
        previous.action = #selector(findPrevious)
        next.target = self
        next.action = #selector(findNext)
        close.target = self
        close.action = #selector(closeClicked)
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
        following = Observer { [weak self] in
            if let found = browser.selected?.found { self?.show(found) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    func present() { isHidden = false }
    func dismiss() { isHidden = true }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// The next match of what's in the field, or the one before.
    func search(backwards: Bool) {
        browser.selected?.find(field.stringValue, backwards: backwards)
    }

    /// "3/12", or "0/0" in red when nothing matches.
    private func show(_ found: Tab.Found) {
        guard !field.stringValue.isEmpty else { count.stringValue = ""; return }
        count.stringValue = found.matches == 0 ? "0/0" : "\((found.current ?? 0) + 1)/\(found.matches)"
        count.textColor = found.matches == 0 ? .systemRed : .secondaryLabelColor
        previous.isEnabled = found.matches > 0
        next.isEnabled = found.matches > 0
    }

    @objc private func findNext() { search(backwards: false) }
    @objc private func findPrevious() { search(backwards: true) }
    @objc private func closeClicked() { onClose() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            search(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose()
            return true
        default:
            return false
        }
    }
}
