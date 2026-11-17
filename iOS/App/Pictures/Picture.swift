import BrowserKit
import UIKit

/// A page as a picture, top aligned and cut to whatever shape it is given:
/// in a card, beside the page during a swipe, under it going back, and
/// standing in for the page while it shrinks into its card.
final class Picture: UIView {
    enum Content {
        /// The page's last picture.
        case image(UIImage)
        /// An exact copy of the page as it shows on screen now.
        case copy(UIView)
        /// A tab never shown since launch: its icon and host instead.
        case site(icon: UIImage?, host: String)
        /// A page nothing is known of.
        case plain
    }

    private let image = UIImageView()
    private let icon = UIImageView()
    private let host = UILabel()
    private var copy: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        clipsToBounds = true
        isUserInteractionEnabled = false
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .tertiaryLabel
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        host.textColor = .secondaryLabel
        host.textAlignment = .center
        host.lineBreakMode = .byTruncatingMiddle
        for view in [image, icon, host] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ content: Content) {
        if copy?.superview === self { copy?.removeFromSuperview() }
        copy = nil
        image.image = nil
        icon.isHidden = true
        host.isHidden = true
        switch content {
        case .image(let picture):
            image.image = picture
        case .copy(let view):
            copy = view
            view.layer.anchorPoint = .zero
            view.transform = .identity
            view.frame.origin = .zero
            addSubview(view)
        case .site(let image, let name):
            icon.image = image ?? UIImage(systemName: "globe")
            icon.isHidden = false
            host.text = name
            host.isHidden = false
        case .plain:
            break
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Everything is sized from the width, so the same picture looks the
    /// same whether it is a card or a whole screen scaled down to one.
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        if let size = image.image?.size, size.width > 0 {
            image.frame = CGRect(x: 0, y: 0, width: width, height: width * size.height / size.width)
        }
        if let copy, copy.bounds.width > 0 {
            let scale = width / copy.bounds.width
            copy.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        guard !icon.isHidden else { return }
        let side = width * 0.19
        icon.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        icon.center = CGPoint(x: bounds.midX, y: bounds.midY - side * 0.3)
        icon.layer.cornerRadius = side * 0.22
        host.font = .systemFont(ofSize: width * 0.065, weight: .medium)
        host.bounds = CGRect(x: 0, y: 0, width: width * 0.8, height: width * 0.1)
        host.center = CGPoint(x: bounds.midX, y: icon.frame.maxY + width * 0.085)
    }
}

extension Picture.Content {
    /// What stands for `tab` when it isn't the live page: its picture, or
    /// for a tab never shown since launch, its icon and host.
    @MainActor
    static func of(_ tab: Tab, in pictures: Pictures) -> Picture.Content {
        if let image = pictures.picture(of: tab) { return .image(image) }
        guard let name = tab.site else { return .plain }
        return .site(icon: tab.icon, host: name)
    }
}
