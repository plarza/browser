import AppKit

/// Over a .user.js file the tab shows as text: the script's name, where it
/// runs, and Install.
@MainActor
final class InstallBar: NSView {
    static let height: CGFloat = 52
    let button = NSButton(title: "Install", target: nil, action: nil)
    var onButton: () -> Void = {}
    private let icon = NSImageView(image: NSImage(systemSymbolName: "curlybraces", accessibilityDescription: nil)!)
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    /// The line under the script's name: its version and sites, or what
    /// went wrong.
    var detailText: String { detail.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        button.bezelStyle = .push
        button.controlSize = .large
        button.target = self
        button.action = #selector(clicked)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text, NSView(), button])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(line)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // The page area's own colour, so the bar reads as the top of the page,
    // and opaque, so the script scrolls under it rather than through it.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    func show(title: String, detail: String, button label: String, enabled: Bool, prominent: Bool) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        button.title = label
        button.isEnabled = enabled
        button.bezelColor = prominent ? .controlAccentColor : nil
    }

    @objc private func clicked() { onButton() }
}
