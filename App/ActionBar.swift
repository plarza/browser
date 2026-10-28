import AppKit
import CoreKit
import WebKit

/// One button per extension that has one, under the address field.
@MainActor
final class ActionBar: NSStackView {
    var onClick: (WKWebExtension.Action, NSView) -> Void = { _, _ in }
    weak var anchor: NSView?
    private var actions: [WKWebExtension.Action] = []

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        actions = Extensions.shared.actions()
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, action) in actions.enumerated() {
            let button = NSButton(image: action.icon(for: NSSize(width: 16, height: 16)) ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!,
                                  target: self, action: #selector(clicked(_:)))
            button.tag = i
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.toolTip = action.label
            button.isEnabled = action.isEnabled
            button.imageScaling = .scaleProportionallyDown
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
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
            addArrangedSubview(button)
        }
        isHidden = actions.isEmpty
    }

    @objc private func clicked(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        onClick(actions[sender.tag], sender)
    }
}
