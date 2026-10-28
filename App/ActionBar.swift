import AppKit
import CoreKit
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
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.enumerated().map { i, action in
            let button = NSButton(image: icon(action), target: self, action: #selector(clicked(_:)))
            button.tag = i
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.toolTip = action.label
            button.isEnabled = action.isEnabled
            button.imageScaling = .scaleProportionallyDown
            if !action.badgeText.isEmpty {
                let badge = NSTextField(labelWithString: action.badgeText)
                badge.font = .systemFont(ofSize: 8, weight: .bold)
                badge.textColor = .white
                badge.wantsLayer = true
                badge.layer?.backgroundColor = NSColor.systemRed.cgColor
                badge.layer?.cornerRadius = 4
                badge.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(badge)
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor).isActive = true
                badge.topAnchor.constraint(equalTo: button.topAnchor).isActive = true
            }
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    private func icon(_ action: WKWebExtension.Action) -> NSImage {
        action.icon(for: NSSize(width: 16, height: 16)) ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!
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
