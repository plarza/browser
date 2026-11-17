import BrowserKit
import UIKit

/// Back and forward: swipes from the screen's left and right edges, as in
/// Safari. Going back, the page follows the finger off to the right, with
/// a shadow, and the page before comes out from under it, moving a third
/// as far. Going forward, the page after slides in over it. Letting go past
/// a third of the way (counting the flick) finishes.
@MainActor
final class EdgeSwipe: NSObject, UIGestureRecognizerDelegate {
    private unowned let pages: PagesController
    private let browser: Browser
    private let backEdge = UIPanGestureRecognizer()
    private let forwardEdge = UIPanGestureRecognizer()
    /// How close to the screen's edge a swipe starts.
    private static let reach: CGFloat = 22
    /// The swipe under way: which way, in which tab, and what shows where
    /// it is going.
    private var swipe: (back: Bool, tab: Tab, target: UIView)?
    private var grabbedAt: CGFloat = 0
    /// How far along the swipe is, in points from the edge.
    private lazy var move = Move(in: pages.view, moving: { [unowned self] in [pages.page] + (swipe.map { [$0.target] } ?? []) }) { [unowned self] in place($0) }

    init(pages: PagesController, browser: Browser) {
        self.pages = pages
        self.browser = browser
    }

    var isMoving: Bool { swipe != nil }

    func install(on view: UIView) {
        for edge in [backEdge, forwardEdge] {
            edge.maximumNumberOfTouches = 1
            edge.addTarget(self, action: #selector(swiped))
            edge.delegate = self
            view.addGestureRecognizer(edge)
        }
    }

    /// Only a touch that starts at its edge of the screen is a swipe's.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let x = touch.location(in: pages.view).x
        return gesture === backEdge ? x <= EdgeSwipe.reach : x >= pages.view.bounds.width - EdgeSwipe.reach
    }

    /// A swipe begins inwards, where the tab has somewhere to go that way.
    /// One already on its way can be caught again from the same edge.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let edge = gesture as? UIPanGestureRecognizer else { return false }
        let back = edge === backEdge
        let velocity = edge.velocity(in: pages.view)
        guard abs(velocity.x) > abs(velocity.y), (velocity.x > 0) == back else { return false }
        if let swipe { return swipe.back == back }
        guard let tab = browser.selected, pages.view.alpha == 1 else { return false }
        return back ? tab.canGoBack : tab.canGoForward
    }

    /// The page's own gestures wait to hear that a touch at the edge
    /// isn't a swipe, as they do for Safari's.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other !== backEdge && other !== forwardEdge
    }

    @objc private func swiped(_ edge: UIPanGestureRecognizer) {
        let back = edge === backEdge
        let direction: CGFloat = back ? 1 : -1
        let along = edge.translation(in: pages.view).x * direction
        let speed = edge.velocity(in: pages.view).x * direction
        switch edge.state {
        case .began:
            // Counted from here, so the page doesn't jump by the distance
            // the finger went before the drag was known for a swipe.
            edge.setTranslation(.zero, in: pages.view)
            if swipe == nil { begin(back: back) }
            grabbedAt = move.hold()
        case .changed:
            move.set(min(pages.view.bounds.width, max(0, grabbedAt + along)))
        case .ended:
            end(speed: speed)
        case .cancelled, .failed:
            end(speed: -.greatestFiniteMagnitude)
        default:
            break
        }
    }

    private func begin(back: Bool) {
        guard let tab = browser.selected else { return }
        let target = picture(of: tab, at: tab.backForward.index + (back ? -1 : 1))
        target.frame = pages.view.bounds
        if back { pages.slider.insertSubview(target, belowSubview: pages.page) } else { pages.slider.addSubview(target) }
        let top = (back ? pages.page : target).layer
        top.shadowColor = UIColor.black.cgColor
        top.shadowOpacity = 0.2
        top.shadowRadius = 12
        top.shadowPath = UIBezierPath(rect: pages.view.bounds).cgPath
        swipe = (back, tab, target)
        move.set(0)
    }

    /// What the page at `index` of `tab`'s list looked like: its picture,
    /// or the new tab page for where a tab began.
    private func picture(of tab: Tab, at index: Int) -> UIView {
        let picture = Picture()
        if let image = pages.pictures.picture(of: tab, at: index) {
            picture.show(.image(image))
        } else if tab.backForward.entries.indices.contains(index), tab.backForward.entries[index] == BackForwardList.blank {
            return NewTabPageView()
        }
        return picture
    }

    /// The top page moves with the finger, the one under it a third as
    /// far, as iOS's own pages do.
    private func place(_ along: CGFloat) {
        guard let swipe else { return }
        let width = pages.view.bounds.width
        if swipe.back {
            pages.page.transform = CGAffineTransform(translationX: along, y: 0)
            swipe.target.transform = CGAffineTransform(translationX: -(width - along) / 3, y: 0)
        } else {
            swipe.target.transform = CGAffineTransform(translationX: width - along, y: 0)
            pages.page.transform = CGAffineTransform(translationX: -along / 3, y: 0)
        }
    }

    private func end(speed: CGFloat) {
        let width = pages.view.bounds.width
        let finishes = move.value + speed * 0.15 > width / 3
        move.spring(to: finishes ? width : 0, velocity: speed.isFinite ? speed : 0) { [weak self] in self?.landed(finished: finishes) }
    }

    /// At rest: the tab goes where the swipe went, the picture staying up
    /// until the real page draws.
    private func landed(finished: Bool) {
        guard let swipe else { return }
        self.swipe = nil
        pages.page.transform = .identity
        swipe.target.transform = .identity
        for layer in [pages.page.layer, swipe.target.layer] { layer.shadowOpacity = 0 }
        swipe.target.removeFromSuperview()
        guard finished, swipe.tab === browser.selected else { return }
        if swipe.back { swipe.tab.goBack() } else { swipe.tab.goForward() }
        // Held once the tab is on its way: a wipe has put its new web view
        // in by now, so the picture goes on top of the page being left.
        if swipe.tab.page == nil, !swipe.tab.isBlank { swipe.tab.view.hold(swipe.target) }
        pages.update()
    }
}
