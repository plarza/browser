import UIKit

/// Behind the grid and the cards: Arc's and Safari's soft lavender.
final class Backdrop: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let gradient = layer as! CAGradientLayer
        gradient.startPoint = .zero
        gradient.endPoint = CGPoint(x: 1, y: 1)
        colour()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (backdrop: Backdrop, _) in backdrop.colour() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func colour() {
        let hexes: [UInt32] = traitCollection.userInterfaceStyle == .dark ? [0x1F1F2B, 0x141419] : [0xE8E6F7, 0xDBDBF0, 0xEBE3ED]
        (layer as! CAGradientLayer).colors = hexes.map { hex in
            UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1).cgColor
        }
    }
}

/// The lavender again, over the top of the grid and fading out downwards,
/// so cards scrolling up fade out under the clock.
final class BackdropFade: UIView {
    private let backdrop = Backdrop()
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(backdrop)
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.locations = [0, 0.45, 1]
        layer.mask = fade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Covers the top of `bounds` down to just under the clock. The
    /// lavender keeps the frame it has behind the grid, so the two line up.
    func layout(in bounds: CGRect, top: CGFloat) {
        frame = CGRect(x: 0, y: 0, width: bounds.width, height: top + 12)
        backdrop.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = self.bounds
        CATransaction.commit()
    }
}

/// A frost behind the clock that fades into the page, so text scrolling up
/// never runs into the clock.
final class Frost: UIVisualEffectView {
    /// The frost's shape. It is also how the frost comes and goes: a blur
    /// can't be faded by its own alpha, but its mask can.
    private let shape = FadingMask()

    init() {
        super.init(effect: UIBlurEffect(style: .systemMaterial))
        isUserInteractionEnabled = false
        mask = shape
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What a move stops when a finger takes over from its spring.
    var moved: UIView { shape }

    /// 0 gone, 1 there: it goes as the grid comes.
    var strength: CGFloat = 1 {
        didSet { shape.alpha = isWanted ? strength : 0 }
    }

    /// A web page is showing. Browser's own pages and the new tab page
    /// have nothing to keep clear of the clock, so there it fades away.
    var isWanted = true {
        didSet {
            guard isWanted != oldValue else { return }
            UIView.animate(withDuration: 0.2) { self.shape.alpha = self.isWanted ? self.strength : 0 }
        }
    }

    func layout(width: CGFloat, top: CGFloat) {
        frame = CGRect(x: 0, y: 0, width: width, height: top + 16)
        shape.frame = bounds
    }

    private final class FadingMask: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        override init(frame: CGRect) {
            super.init(frame: frame)
            let gradient = layer as! CAGradientLayer
            gradient.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
            gradient.locations = [0, 0.7, 1]
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }
}
