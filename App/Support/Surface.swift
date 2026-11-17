import AppKit

/// The sidebar and the page area: pure white (black in dark mode), flush
/// with each other with no line between them, or clear over the new tab
/// page, which draws the glass (see `NewTabPage.glassWidth`).
@MainActor
class Surface: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    var isClear = false { didSet { if isClear != oldValue { needsDisplay = true } } }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isClear ? NSColor.clear.cgColor : NSColor.textBackgroundColor.cgColor
        }
    }
}
