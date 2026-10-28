import AppKit
import AzoteKit
import WebKit

/// Extensions' buttons, beside the traffic lights: as many as fit, left to
/// right, and the rest in a menu behind the button at the far right.
@MainActor
final class ActionBar: NSView {
    var onClick: (WKWebExtension.Action, NSView) -> Void = { _, _ in }
    weak var anchor: NSView?
    private var actions: [WKWebExtension.Action] = []
    private var buttons: [NSButton] = []
    private let more = NSButton()
    private static let step: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        more.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "More Extensions")
        more.isBordered = false
        more.bezelStyle = .accessoryBarAction
        more.contentTintColor = .secondaryLabelColor
        more.toolTip = "More Extensions"
        more.target = self
        more.action = #selector(showMore)
        addSubview(more)
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        actions = Extensions.shared.actions()
        // Updating an icon or badge must keep the popup's anchor alive.
        if buttons.count != actions.count {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = actions.indices.map { _ in
                let button = NSButton()
                button.isBordered = false
                button.bezelStyle = .accessoryBarAction
                button.imageScaling = .scaleProportionallyDown
                button.target = self
                button.action = #selector(clicked(_:))
                button.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
                let badge = NSTextField(labelWithString: "")
                badge.font = .systemFont(ofSize: 8, weight: .bold)
                badge.textColor = .white
                badge.wantsLayer = true
                badge.layer?.backgroundColor = NSColor.systemRed.cgColor
                badge.layer?.cornerRadius = 4
                badge.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(badge)
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor).isActive = true
                badge.topAnchor.constraint(equalTo: button.topAnchor).isActive = true
                addSubview(button)
                return button
            }
        }
        for (i, action) in actions.enumerated() {
            let button = buttons[i]
            button.tag = i
            button.image = icon(action)
            button.toolTip = action.label
            button.isEnabled = action.isEnabled
            let badge = button.subviews.first as? NSTextField
            badge?.stringValue = action.badgeText
            badge?.isHidden = action.badgeText.isEmpty
        }
        needsLayout = true
    }

    private func icon(_ action: WKWebExtension.Action) -> NSImage {
        let image = (action.icon(for: NSSize(width: 16, height: 16))
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!).copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// How many fit; with any left over, the last place is the menu's.
    private var shown: Int {
        let fit = Int(bounds.width / Self.step)
        return buttons.count <= fit ? buttons.count : max(0, fit - 1)
    }

    override func layout() {
        super.layout()
        let count = shown
        for (i, button) in buttons.enumerated() {
            button.isHidden = i >= count
            button.frame = NSRect(x: CGFloat(i) * Self.step, y: (bounds.height - 22) / 2, width: 24, height: 22)
        }
        more.isHidden = count == buttons.count
        more.frame = NSRect(x: bounds.width - 24, y: (bounds.height - 22) / 2, width: 24, height: 22)
    }

    @objc private func dragged(_ gesture: NSPanGestureRecognizer) {
        guard let button = gesture.view as? NSButton, shown > 0, actions.indices.contains(button.tag) else { return }
        let target = min(max(Int(gesture.location(in: self).x / Self.step), 0), shown - 1)
        switch gesture.state {
        case .began, .changed:
            button.frame.origin.x = min(max(gesture.location(in: self).x - 12, 0), CGFloat(shown - 1) * Self.step)
        case .ended:
            var order = actions
            let moved = order.remove(at: button.tag)
            order.insert(moved, at: target)
            let next = target + 1 < order.count ? order[target + 1].webExtensionContext?.uniqueIdentifier : nil
            if let id = moved.webExtensionContext?.uniqueIdentifier { Extensions.shared.move(id, before: next) }
        default: needsLayout = true
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        onClick(actions[sender.tag], sender)
    }

    @objc private func showMore() {
        let menu = NSMenu()
        for i in shown ..< actions.count {
            let item = NSMenuItem(title: actions[i].label, action: #selector(pick(_:)), keyEquivalent: "")
            item.image = icon(actions[i])
            item.tag = i
            item.target = self
            item.isEnabled = actions[i].isEnabled
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard actions.indices.contains(item.tag) else { return }
        onClick(actions[item.tag], more)
    }
}
