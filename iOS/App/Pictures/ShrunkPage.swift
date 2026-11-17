import UIKit

/// The page as a picture, standing in for it wherever the page itself
/// can't go: shrinking into its card as the grid opens, and stepped back
/// behind the address sheet. WebKit moves a page's scroll position when it
/// sees its own view scaled, so the live page never is.
///
/// Everything it places is linear in how far the grid is open, so Core
/// Animation's own interpolation of it is exact.
final class ShrunkPage: UIView {
    /// Cuts the picture to the card's shape; scaled about its top left.
    private let cut = UIView()
    private let picture = Picture()
    /// The card to shrink into, on screen. Without one the page shrinks
    /// towards the middle and fades.
    var card: CGRect?
    private(set) var isStandingIn = false
    private var leaving = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        cut.layer.anchorPoint = .zero
        cut.layer.cornerCurve = .continuous
        cut.clipsToBounds = true
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cut.addSubview(picture)
        addSubview(cut)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The views whose springs a move stops when a finger takes over.
    var moved: [UIView] { [cut, picture] + picture.subviews }

    /// Stands in for the page from now, showing `content`.
    func standIn(with content: Picture.Content) {
        leaving += 1
        layer.removeAllAnimations()
        alpha = 1
        isHidden = false
        isStandingIn = true
        picture.show(content)
    }

    /// The page, or its card, is showing again underneath: the picture goes,
    /// fading so that whatever changed while it stood in doesn't pop.
    func standDown() {
        guard isStandingIn else { return }
        isStandingIn = false
        leaving += 1
        let number = leaving
        UIView.animate(withDuration: 0.12, delay: 0, options: .curveEaseOut) {
            self.alpha = 0
        } completion: { _ in
            guard self.leaving == number else { return }
            self.isHidden = true
            self.picture.show(.plain)
        }
    }

    /// With the grid `open` from 0 (the page) to 1 (its card): scaled to
    /// the card's width, cut to its height, its corners going from the
    /// screen's own to the card's.
    func place(_ open: CGFloat) {
        let screen = bounds
        guard screen.width > 0 else { return }
        let target = card ?? screen.insetBy(dx: screen.width * 0.2, dy: screen.height * 0.2)
        let fit = target.width / screen.width
        let radius = Look.screenRadius(of: self)
        cut.bounds = CGRect(x: 0, y: 0, width: screen.width, height: screen.height + (target.height / fit - screen.height) * open)
        cut.center = CGPoint(x: target.minX * open, y: target.minY * open)
        let scale = 1 + (fit - 1) * open
        cut.transform = CGAffineTransform(scaleX: scale, y: scale)
        cut.layer.cornerRadius = radius + (Look.cardRadius / fit - radius) * open
        cut.alpha = card == nil ? 1 - open : 1
        // Inside a spring's block, so what the picture lays out moves with it.
        picture.layoutIfNeeded()
    }
}
