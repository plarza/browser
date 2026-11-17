import AppKit

extension NSView {
    /// Adds `child` flush with all four edges, below `sibling` if given.
    func addPinned(_ child: NSView, below sibling: NSView? = nil) {
        child.translatesAutoresizingMaskIntoConstraints = false
        if let sibling { addSubview(child, positioned: .below, relativeTo: sibling) } else { addSubview(child) }
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// The event landed on this view.
    func contains(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// Dark mode, as this view is drawn.
    var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
