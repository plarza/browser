import AppKit
import BrowserKit

/// Two-finger swipes left and right go back and forward, as in Safari.
/// Browser keeps its own back and forward lists (a wipe swaps the web view
/// out), so the swipe is followed here, from the scroll gesture's phases:
/// going back, the page follows the fingers off to the right, a picture
/// of the page before coming out from under it; going forward, the page
/// after slides in over it. Letting go far enough, or with a flick,
/// finishes, and the picture stays until the next page draws.
@MainActor
final class SwipeNavigation {
    let pictures: PagePictures
    private let browser: Browser
    private let pageArea: PageArea
    private var monitor: EventMonitor?

    /// The swipe under way: the tab it started in, which way, how far the
    /// fingers have gone and their last step, and the other page's picture.
    private struct Swipe {
        let tab: Tab
        let back: Bool
        var distance: CGFloat
        var last: CGFloat
        let picture: NSImageView
    }

    private var swipe: Swipe?

    init(browser: Browser, pageArea: PageArea) {
        self.browser = browser
        self.pageArea = pageArea
        pictures = PagePictures(browser: browser)
        monitor = EventMonitor(.scrollWheel) { [weak self] event in
            self?.scrolled(event)
            return false
        }
    }

    private func scrolled(_ event: NSEvent) {
        guard event.window === pageArea.window else { return }
        let onPage = pageArea.contains(event)
        // A swipe under way follows the fingers off the page too, so
        // it always ends; only a new one has to start on the page.
        guard onPage || swipe != nil else { return }
        // The page came to rest: its picture, for swiping back to it.
        if onPage, event.phase == .ended || event.momentumPhase == .ended { pictures.captureSoon() }
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return }
        follow(event.phase, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
    }

    /// One step of the scroll gesture.
    func follow(_ phase: NSEvent.Phase, dx: CGFloat, dy: CGFloat) {
        guard let tab = browser.selected else { return }
        let stage = pageArea.stage
        switch phase {
        case .began:
            guard abs(dx) > abs(dy) * 2 else { return }
            // Fingers moving right (a positive delta) mean back.
            let back = dx > 0
            guard swipe == nil, back ? tab.canGoBack : tab.canGoForward, tab.page == nil, !stage.isHidden,
                  stage.page === tab.view else { return }
            pictures.capture(tab)
            let picture = NSImageView(frame: pageArea.bounds)
            picture.imageScaling = .scaleAxesIndependently
            picture.image = pictures.picture(of: tab, at: tab.backForward.index + (back ? -1 : 1))
            picture.wantsLayer = true
            picture.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            stage.add(picture, below: back)
            let top = back ? tab.view : picture
            top.wantsLayer = true
            top.layer?.shadowColor = NSColor.black.cgColor
            top.layer?.shadowOpacity = 0.2
            top.layer?.shadowRadius = 12
            top.layer?.shadowPath = CGPath(rect: pageArea.bounds, transform: nil)
            swipe = Swipe(tab: tab, back: back, distance: abs(dx), last: abs(dx), picture: picture)
            place()
        case .changed:
            guard let current = swipe else { return }
            let step = current.back ? dx : -dx
            swipe?.distance = min(pageArea.bounds.width, max(0, current.distance + step))
            swipe?.last = step
            place()
        case .ended, .cancelled:
            guard let current = swipe else { return }
            guard current.tab === tab else { return cancel() }
            let width = pageArea.bounds.width
            let done = phase == .ended && (current.distance > width / 4 || current.last > 6 && current.distance > 40)
            swipe?.distance = done ? width : 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                place(animated: true)
            } completionHandler: {
                MainActor.assumeIsolated { self.settle(current.picture, done: done) }
            }
        default:
            break
        }
    }

    /// The page the fingers move, and under it, a third as far, the other.
    private func place(animated: Bool = false) {
        guard let swipe, swipe.tab === browser.selected else { return }
        let page = swipe.tab.view
        let width = pageArea.bounds.width, x = swipe.distance
        let (moving, under) = swipe.back ? (x, -(width - x) / 3) : (-x / 3, width - x)
        (animated ? page.animator() : page).setFrameOrigin(NSPoint(x: moving, y: 0))
        (animated ? swipe.picture.animator() : swipe.picture).setFrameOrigin(NSPoint(x: under, y: 0))
    }

    /// The swipe of `picture` settled: it goes back or forward if `done` and
    /// it is still the swipe under way, in the tab still showing.
    private func settle(_ picture: NSImageView, done: Bool) {
        guard let swipe, swipe.picture === picture else { return }
        cancel()
        guard done, swipe.tab === browser.selected else { return }
        // The picture stays over the page until the next one draws.
        swipe.tab.view.hold(picture)
        if swipe.back { swipe.tab.goBack() } else { swipe.tab.goForward() }
    }

    /// The swipe stops where it is: its page back in place, its picture
    /// gone. Any other tab showing, a new swipe, or the swipe settling ends it.
    private func cancel() {
        guard let swipe else { return }
        self.swipe = nil
        swipe.tab.view.frame = pageArea.stage.bounds
        swipe.tab.view.layer?.shadowOpacity = 0
        swipe.picture.layer?.shadowOpacity = 0
        swipe.picture.removeFromSuperview()
    }

    /// A swipe belongs to the tab it started in: `tab` showing ends any other's.
    func end(unlessIn tab: Tab?) {
        if swipe?.tab !== tab { cancel() }
    }
}
