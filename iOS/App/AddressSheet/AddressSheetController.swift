import BrowserKit
import SwiftUI
import UIKit

/// The address sheet: glass, up from the bottom. What's behind steps back
/// into a card above it; tapping the card, or pulling the sheet down, puts
/// the sheet away.
final class AddressSheetController: UIViewController, UIGestureRecognizerDelegate {
    /// What was typed or picked: true if the sheet has done its job.
    private let go: (String, AddressSheetTarget) -> Bool
    /// The sheet has come to rest, up or down.
    private let landed: () -> Void
    /// What's behind, which steps back as the sheet comes up.
    private let behind: UIView

    private let sheet = UIView()
    private let card = UIControl()
    private let content = UIHostingController(rootView: AddressSheet?.none)
    private var target = AddressSheetTarget.newTab
    private var grabbedAt: CGFloat = 0

    /// How far up the sheet is: 0 away, 1 up.
    private(set) lazy var move = Move(in: view, moving: { [unowned self] in [sheet, behind] }) { [unowned self] in place($0) }

    init(behind: UIView, go: @escaping (String, AddressSheetTarget) -> Bool, landed: @escaping () -> Void) {
        self.behind = behind
        self.go = go
        self.landed = landed
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isUp: Bool { move.value > 0 || move.isMoving }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isHidden = true
        card.addAction(UIAction { [weak self] _ in self?.lower() }, for: .touchUpInside)
        card.accessibilityLabel = "Close"
        view.addSubview(card)
        view.addSubview(sheet)

        addChild(content)
        content.view.backgroundColor = .clear
        content.view.frame = sheet.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sheet.addSubview(content.view)
        content.didMove(toParent: self)

        let pull = UIPanGestureRecognizer(target: self, action: #selector(pulled))
        pull.delegate = self
        sheet.addGestureRecognizer(pull)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !move.isMoving else { return }
        // The card above shows this much of what stepped back.
        let top = view.safeAreaInsets.top + 130
        card.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: top)
        sheet.transform = .identity
        sheet.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: view.bounds.height - top)
        place(move.value)
    }

    /// The sheet `up` from 0 to 1, and what's behind stepped back by as
    /// much: scaled to 92% from its top, 36 pt down, its corners rounded.
    private func place(_ up: CGFloat) {
        sheet.transform = CGAffineTransform(translationX: 0, y: (1 - up) * sheet.bounds.height)
        let scale = 1 - 0.08 * up
        // Scaled about the middle of its top edge.
        behind.transform = CGAffineTransform(translationX: 0, y: 36 * up - behind.bounds.height * (1 - scale) / 2).scaledBy(x: scale, y: scale)
        let screen = Look.screenRadius(of: view)
        behind.layer.cornerRadius = screen + (Look.steppedRadius / 0.92 - screen) * up
    }

    // MARK: Up and down

    /// Comes up, the field focused: on the tab's address, selected to type
    /// over, or empty for a new tab.
    func raise(for target: AddressSheetTarget, address: String) {
        self.target = target
        view.isHidden = false
        view.layoutIfNeeded()
        content.rootView = AddressSheet(address: address) { [weak self] text in self?.submit(text) }
        content.view.layoutIfNeeded()
        move.spring(to: 1)
    }

    /// Goes away, at the finger's speed if a finger let it go.
    func lower(velocity: CGFloat = 0) {
        view.endEditing(true)
        move.spring(to: 0, velocity: velocity) { [weak self] in
            guard let self else { return }
            view.isHidden = true
            content.rootView = nil
            landed()
        }
    }

    private func submit(_ text: String) {
        if go(text, target) { lower() }
    }

    // MARK: Pulling it down

    /// A pull begins downwards, and not on a list that has somewhere to
    /// scroll back to.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pull = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pull.velocity(in: view)
        guard velocity.y > abs(velocity.x) else { return false }
        var view = sheet.hitTest(pull.location(in: sheet), with: nil)
        while let inside = view, inside !== sheet {
            if let scroll = inside as? UIScrollView, scroll.contentOffset.y > -scroll.adjustedContentInset.top { return false }
            view = inside.superview
        }
        return true
    }

    /// The list waits for the pull to say whether the drag is its.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView
    }

    @objc private func pulled(_ pull: UIPanGestureRecognizer) {
        let height = sheet.bounds.height
        let down = pull.translation(in: view).y, speed = pull.velocity(in: view).y
        switch pull.state {
        case .began:
            grabbedAt = move.hold()
        case .changed:
            move.set(min(1, max(0, grabbedAt - down / height)))
        case .ended, .cancelled, .failed:
            if pull.state == .ended, (1 - move.value) * height + speed * 0.15 > 140 {
                lower(velocity: -speed / height)
            } else {
                move.spring(to: 1, velocity: -speed / height) { [weak self] in self?.landed() }
            }
        default:
            break
        }
    }
}
