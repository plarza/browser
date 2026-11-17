import BrowserKit
import UIKit

/// A tab in the grid: a picture of its page, its favicon and title
/// underneath, and an ✕ in its corner. Swiping it sideways closes it.
final class Card: UICollectionViewCell, UIGestureRecognizerDelegate {
    static let spacing: CGFloat = 14
    /// The picture's shape: a little taller than wide.
    private static let aspect: CGFloat = 0.78
    private static let caption: CGFloat = 27

    static func pictureHeight(forWidth width: CGFloat) -> CGFloat { (width / aspect).rounded() }
    static func height(forWidth width: CGFloat) -> CGFloat { pictureHeight(forWidth: width) + caption }

    private(set) var tab: Tab?
    private var closeTab: (() async -> Bool)?
    private var following: Observer?

    /// Casts the shadow, which the picture's rounded corners would cut off.
    private let shadow = UIView()
    private let picture = Picture()
    private let ring = UIView()
    private let closeButton = UIButton(configuration: .glass())
    private let icon = UIImageView()
    private let title = UILabel()

    private var grabbedAt: CGFloat = 0
    /// How far the card has been swiped aside, in points.
    private lazy var swipe = Move(in: self, moving: { [unowned self] in [contentView] }) { [unowned self] aside in
        contentView.transform = CGAffineTransform(translationX: aside, y: 0)
        contentView.alpha = 1 - min(0.7, abs(aside) / 260)
    }

    /// The page is on its way to or from this card: its picture, in
    /// flight, stands in for the card's.
    var isAway = false {
        didSet { picture.alpha = isAway ? 0 : 1 }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.13
        shadow.layer.shadowRadius = 10
        shadow.layer.shadowOffset = CGSize(width: 0, height: 4)
        picture.layer.cornerRadius = Look.cardRadius
        picture.layer.cornerCurve = .continuous
        ring.isUserInteractionEnabled = false
        ring.layer.cornerRadius = Look.cardRadius
        ring.layer.cornerCurve = .continuous
        ring.layer.borderColor = Look.persist.cgColor
        ring.layer.borderWidth = 3

        closeButton.configuration?.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        closeButton.configuration?.contentInsets = .zero
        closeButton.configuration?.cornerStyle = .capsule
        closeButton.tintColor = .label
        closeButton.accessibilityLabel = "Close Tab"
        closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)

        icon.contentMode = .scaleAspectFit
        icon.tintColor = .tertiaryLabel
        icon.layer.cornerRadius = 3.5
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        shadow.addSubview(picture)
        for view in [shadow, ring, closeButton, icon, title] { contentView.addSubview(view) }

        let aside = UIPanGestureRecognizer(target: self, action: #selector(swiped))
        aside.delegate = self
        addGestureRecognizer(aside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let shape = CGRect(x: 0, y: 0, width: width, height: Card.pictureHeight(forWidth: width))
        shadow.frame = shape
        shadow.layer.shadowPath = UIBezierPath(roundedRect: shape, cornerRadius: Look.cardRadius).cgPath
        picture.frame = shape
        ring.frame = shape
        closeButton.frame = CGRect(x: width - 33, y: 7, width: 26, height: 26)
        icon.frame = CGRect(x: 4, y: shape.maxY + 8, width: 16, height: 16)
        title.frame = CGRect(x: 26, y: shape.maxY + 7, width: width - 30, height: 18)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        following?.cancel()
        following = nil
        tab = nil
        swipe.set(0)
    }

    /// Shows `tab`, and keeps showing it as it changes.
    func show(_ tab: Tab, pictures: Pictures, close: @escaping () async -> Bool) {
        self.tab = tab
        closeTab = close
        following?.cancel()
        following = Observer { [weak self, weak tab] in
            guard let self, let tab else { return }
            picture.show(.of(tab, in: pictures))
            ring.isHidden = !tab.persist
            title.text = tab.cardTitle
            icon.image = tab.icon ?? UIImage(systemName: "globe")
            accessibilityLabel = tab.cardTitle
        }
    }

    /// What a long press lifts: the picture, in its own shape.
    var preview: UITargetedPreview {
        let shape = UIPreviewParameters()
        shape.visiblePath = UIBezierPath(roundedRect: shadow.bounds, cornerRadius: Look.cardRadius)
        shape.backgroundColor = .clear
        return UITargetedPreview(view: shadow, parameters: shape)
    }

    // MARK: Closing

    /// Closes the tab; back in its place if a Persist tab's question was
    /// answered no.
    func close() {
        Task {
            guard let closeTab, await !closeTab() else { return }
            swipe.spring(to: 0)
        }
    }

    /// A swipe begins sideways; anything else is the grid scrolling.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, pan.view === self else { return super.gestureRecognizerShouldBegin(gesture) }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y) * 1.5
    }

    @objc private func swiped(_ pan: UIPanGestureRecognizer) {
        let aside = pan.translation(in: self).x, speed = pan.velocity(in: self).x
        switch pan.state {
        case .began:
            grabbedAt = swipe.hold()
        case .changed:
            swipe.set(grabbedAt + aside)
        case .ended:
            let reach = swipe.value + speed * 0.15
            guard abs(reach) > 160 else { return swipe.spring(to: 0, velocity: speed) }
            // Flung off its side, then closed.
            swipe.spring(to: reach > 0 ? 420 : -420, velocity: speed)
            close()
        case .cancelled, .failed:
            swipe.spring(to: 0)
        default:
            break
        }
    }
}
