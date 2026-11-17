import AppKit
import BrowserKit
import CoreImage

/// What a blank tab shows behind nothing: the chosen picture filling the
/// page, a colour, or the desktop, frosted through the window. With Fill on
/// it spans the window, and the sidebar's part of it is glass: the picture
/// blurred and tinted with the sidebar's own colour (white, or black in dark
/// mode), by Settings' amounts.
@MainActor
final class NewTabPage: NSView {
    private let picture = CALayer()
    private let frost = NSVisualEffectView()
    private let glass = NSView()
    private let blurred = CALayer()
    private let tint = CALayer()
    private var settings = Settings()
    private var following: Observer?

    /// A picture file as it was at one moment: choosing another keeps the
    /// address and bumps the version.
    private struct Source: Equatable {
        let image: URL
        let version: Int
    }

    private struct Blur: Equatable {
        let source: Source
        let radius: Double
    }

    private var shown: Source?
    /// The blur last asked for, and whether one is being made. One at a time,
    /// always of the latest ask, so dragging the slider never queues work.
    private var wantedBlur: Blur?
    private var shownBlur: Blur?
    private var blurring = false
    /// The picture decoded at blur size, kept while it stays the same.
    private var decoded: (source: Source, picture: CGImage)?

    /// How much of the left edge is under the sidebar; 0 without Fill.
    private(set) var glassWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        layer?.addSublayer(picture)
        frost.material = .underWindowBackground
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.autoresizingMask = [.width, .height]
        addSubview(frost)
        glass.wantsLayer = true
        glass.layer?.masksToBounds = true
        blurred.contentsGravity = .resizeAspectFill
        glass.layer?.addSublayer(blurred)
        glass.layer?.addSublayer(tint)
        addSubview(glass)
        following = Observer { [weak self] in
            self?.show(Preferences.shared.settings, imageVersion: Preferences.shared.newTabImageVersion)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The glass under the sidebar, as wide as it is; it slides with the
    /// sidebar when `animated`, inside the sidebar's own animation.
    func setGlassWidth(_ width: CGFloat, animated: Bool) {
        guard width != glassWidth else { return }
        glassWidth = width
        let frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        if animated { glass.animator().frame = frame } else { glass.frame = frame }
    }

    private func show(_ settings: Settings, imageVersion: Int) {
        self.settings = settings
        frost.isHidden = settings.newTabPage != .blank
        picture.isHidden = settings.newTabPage != .image
        layer?.backgroundColor = settings.newTabPage == .color ? NSColor(hex: settings.newTabColor).cgColor : NSColor.clear.cgColor
        let source = Settings.newTabImageInUse.map { Source(image: $0, version: imageVersion) }
        if settings.newTabPage == .image, source != shown {
            shown = source
            picture.contents = source.flatMap { NSImage(contentsOf: $0.image) }
        }
        updateTint()
        blurred.isHidden = settings.newTabPage != .image
        if settings.newTabPage == .image, settings.fill, let source {
            // Up to 50 points of blur at the far end.
            wantedBlur = Blur(source: source, radius: settings.fillBlur * 50 / Settings.fillMax)
            blurNext()
        }
        needsLayout = true
    }

    private func blurNext() {
        guard !blurring, let wanted = wantedBlur else { return }
        wantedBlur = nil
        if shownBlur == wanted { return }
        blurring = true
        let ready = decoded.flatMap { $0.source == wanted.source ? $0.picture : nil }
        Task.detached(priority: .userInitiated) {
            let picture = ready ?? NewTabPage.decode(wanted.source.image)
            let blurred = picture.flatMap { NewTabPage.blur($0, radius: wanted.radius) }
            await MainActor.run {
                if let picture { self.decoded = (wanted.source, picture) }
                self.blurred.contents = blurred
                self.shownBlur = wanted
                self.blurring = false
                self.blurNext()
            }
        }
    }

    /// The sidebar's colour over the glass: none at full transparency,
    /// nearly opaque at none.
    private func updateTint() {
        let alpha = 0.92 * (1 - settings.fillTransparency / Settings.fillMax)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(alpha).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    nonisolated private static let context = CIContext()

    /// The picture at 1600 points wide at most.
    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard let image = CIImage(contentsOf: url) else { return nil }
        let scale = min(1, 1600 / image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }

    /// Blurred with its edges held.
    nonisolated private static func blur(_ picture: CGImage, radius: Double) -> CGImage? {
        let image = CIImage(cgImage: picture)
        guard radius > 0 else { return picture }
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
        return context.createCGImage(blurred, from: image.extent)
    }

    override func layout() {
        super.layout()
        glass.frame = NSRect(x: 0, y: 0, width: glassWidth, height: bounds.height)
        CATransaction.run {
            picture.frame = bounds
            frost.frame = bounds
            // The blurred copy lies exactly over the picture, cut to the
            // sidebar by the glass; the tint with it.
            blurred.frame = bounds
            tint.frame = bounds
        }
    }
}
