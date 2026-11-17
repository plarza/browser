import AppKit
import BrowserKit
import WebKit

/// Extensions' buttons, beside the traffic lights: as many as fit, left to
/// right, and the rest in a menu behind the button at the far right. After
/// them, while any userscript is installed, the userscripts' button.
@MainActor
final class ActionBar: NSView {
    /// The userscripts' button: what runs on this page, and their commands.
    let scripts = ActionBar.button("curlybraces", "Userscripts")
    let scriptsMenu: ScriptsMenu
    /// How many scripts ran on the page showing.
    private(set) var running = 0
    /// The button an extension's popup hangs from.
    private(set) weak var anchor: NSView?

    private let scriptsBadge = ActionBar.badge()
    private let more = ActionBar.button("puzzlepiece.extension", "More Extensions")
    private var actions: [WKWebExtension.Action] = []
    private var buttons: [NSButton] = []
    private var following: [Observer] = []
    private static let step: CGFloat = 26

    init(browser: Browser) {
        scriptsMenu = ScriptsMenu(browser: browser)
        super.init(frame: .zero)
        more.target = self
        more.action = #selector(showMore)
        addSubview(more)
        scripts.target = self
        scripts.action = #selector(openScriptsMenu)
        scripts.isHidden = true
        ActionBar.pin(scriptsBadge, to: scripts)
        addSubview(scripts)
        following = [
            Observer { [weak self] in self?.show(Extensions.shared.actions) },
            Observer { [weak self] in
                let page = browser.selected.flatMap { $0.page == nil ? $0.webView : nil }
                let running = Userscripts.shared.scripts(on: page).filter(\.running).count
                self?.showScripts(installed: !Userscripts.shared.scripts.isEmpty, running: running)
            },
        ]
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, _ label: String) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        return button
    }

    /// The small red count in a button's corner.
    private static func badge() -> NSTextField {
        let badge = NSTextField(labelWithString: "")
        badge.font = .systemFont(ofSize: 8, weight: .bold)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 4
        badge.translatesAutoresizingMaskIntoConstraints = false
        return badge
    }

    private static func pin(_ badge: NSTextField, to button: NSButton) {
        button.addSubview(badge)
        badge.trailingAnchor.constraint(equalTo: button.trailingAnchor).isActive = true
        badge.topAnchor.constraint(equalTo: button.topAnchor).isActive = true
    }

    // MARK: Extensions

    private func show(_ actions: [WKWebExtension.Action]) {
        self.actions = actions
        // Updating an icon or badge must keep the popup's anchor alive.
        if buttons.count != actions.count {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = actions.map { _ in
                let button = NSButton()
                button.isBordered = false
                button.bezelStyle = .accessoryBarAction
                button.imageScaling = .scaleProportionallyDown
                button.target = self
                button.action = #selector(clicked(_:))
                button.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
                ActionBar.pin(ActionBar.badge(), to: button)
                addSubview(button)
                return button
            }
        }
        for (place, action) in actions.enumerated() {
            let button = buttons[place]
            button.tag = place
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
        let fit = Int(bounds.width / ActionBar.step) - (scripts.isHidden ? 0 : 1)
        return buttons.count <= fit ? buttons.count : max(0, fit - 1)
    }

    override func layout() {
        super.layout()
        let count = shown
        let place = { (x: CGFloat) in NSRect(x: x, y: (self.bounds.height - 24) / 2, width: 24, height: 24) }
        for (index, button) in buttons.enumerated() {
            button.isHidden = index >= count
            button.frame = place(CGFloat(index) * ActionBar.step)
        }
        more.isHidden = count == buttons.count
        more.frame = place(bounds.width - 24)
        scripts.frame = place(CGFloat(count) * ActionBar.step)
    }

    /// A button dragged along the row takes the place it is let go over;
    /// the order is saved.
    @objc private func dragged(_ gesture: NSPanGestureRecognizer) {
        guard let button = gesture.view as? NSButton, shown > 0, actions.indices.contains(button.tag) else { return }
        let x = gesture.location(in: self).x
        let target = min(max(Int(x / ActionBar.step), 0), shown - 1)
        switch gesture.state {
        case .began, .changed:
            button.frame.origin.x = min(max(x - 12, 0), CGFloat(shown - 1) * ActionBar.step)
        case .ended:
            var order = actions
            let moved = order.remove(at: button.tag)
            order.insert(moved, at: target)
            let next = target + 1 < order.count ? order[target + 1].webExtensionContext?.uniqueIdentifier : nil
            if let id = moved.webExtensionContext?.uniqueIdentifier { Extensions.shared.move(id, before: next) }
            needsLayout = true
        default:
            needsLayout = true
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        perform(actions[sender.tag], from: sender)
    }

    /// The buttons that didn't fit, as a menu.
    @objc private func showMore() {
        let menu = NSMenu()
        for place in shown ..< actions.count {
            let item = NSMenuItem(title: actions[place].label, action: #selector(pick(_:)), keyEquivalent: "")
            item.image = icon(actions[place])
            item.tag = place
            item.target = self
            item.isEnabled = actions[place].isEnabled
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard actions.indices.contains(item.tag) else { return }
        perform(actions[item.tag], from: more)
    }

    /// The extension does what its button does; a popup, if it has one,
    /// hangs from `button`.
    private func perform(_ action: WKWebExtension.Action, from button: NSView) {
        anchor = button
        Extensions.shared.perform(action)
    }

    // MARK: Userscripts

    private func showScripts(installed: Bool, running: Int) {
        scripts.isHidden = !installed
        self.running = running
        scriptsBadge.stringValue = running > 0 ? "\(running)" : ""
        scriptsBadge.isHidden = running == 0
        scripts.contentTintColor = running > 0 ? .labelColor : .secondaryLabelColor
        needsLayout = true
    }

    @objc private func openScriptsMenu() { scriptsMenu.show(from: scripts) }
}
