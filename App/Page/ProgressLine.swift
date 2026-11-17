import AppKit
import BrowserKit

/// A two-point line across the top of the page while it loads.
@MainActor
final class ProgressLine: NSView {
    private let bar = CALayer()
    private var value = 1.0
    private var following: Observer?

    init(browser: Browser) {
        super.init(frame: .zero)
        wantsLayer = true
        bar.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(bar)
        alphaValue = 0
        following = Observer { [weak self] in
            guard let tab = browser.selected else { return }
            self?.set(tab.isLoading ? tab.progress : 1)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func set(_ value: Double) {
        let done = value >= 1
        if !done && self.value >= 1 {
            // A new load: start from nothing, without animating back.
            CATransaction.run { bar.frame.size.width = 0 }
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
