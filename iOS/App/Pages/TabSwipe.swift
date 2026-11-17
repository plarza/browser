import BrowserKit
import SwiftUI
import UIKit

/// Dragging the address bar sideways: the next or previous tab comes in
/// beside the page, 12 pt apart, as in Safari. Letting go past a third of
/// the way (counting the flick) moves to that tab; at the first or last
/// tab the page only gives a little.
@MainActor
final class TabSwipe {
    private unowned let pages: PagesController
    private let browser: Browser
    private let bar: Bar
    /// How far the page has been slid, in points.
    private(set) lazy var move = Move(in: pages.view, moving: { [unowned self] in [pages.slider] }) { [unowned self] offset in
        pages.slider.transform = CGAffineTransform(translationX: offset, y: 0)
    }
    private var grabbedAt: CGFloat = 0

    init(pages: PagesController, browser: Browser, bar: Bar) {
        self.pages = pages
        self.browser = browser
        self.bar = bar
    }

    /// From one tab's page to the next.
    private var step: CGFloat { pages.view.bounds.width + Look.gap }

    func began() {
        grabbedAt = move.hold()
    }

    func changed(by translation: CGFloat) {
        var offset = grabbedAt + translation
        let (previous, next) = browser.neighbours
        if (offset > 0 ? previous : next) == nil { offset /= 4 }
        move.set(offset)
        follow(offset)
    }

    func ended(velocity: CGFloat) {
        let offset = move.value
        let width = pages.view.bounds.width
        let (previous, next) = browser.neighbours
        let reach = offset + velocity * 0.15
        let target = reach > width / 3 ? previous : reach < -width / 3 ? next : nil
        bar.named = nil
        if let target {
            // Selected at once, so the address and the stack are the new
            // tab's while the pages carry on to rest.
            browser.select(target)
            pages.update()
        }
        settle(velocity: velocity)
    }

    /// The page showing was swapped for the tab beside it, by this swipe or
    /// by itself (a link's new tab, a popup): the new page comes in from
    /// its side, the old one going off the other.
    func arrived(at tab: Tab, from old: Tab) {
        guard let new = browser.index(of: tab), let before = browser.index(of: old), abs(new - before) == 1 else { return }
        // The pages are already swapped: put back where they showed, then let go.
        let showing = move.isMoving ? move.shown : 0
        move.set(showing + (new > before ? step : -step))
        if bar.position == nil { bar.position = CGFloat(before) }
        if !move.isHeld { settle(velocity: 0) }
    }

    /// The page springs to rest, the stack dealing along with it.
    private func settle(velocity: CGFloat) {
        let offset = move.value
        let index = CGFloat(browser.index(of: browser.selected) ?? 0)
        withAnimation(Move.animation(velocity: offset == 0 ? 0 : -velocity / offset)) { bar.position = index }
        move.spring(to: 0, velocity: velocity) { [bar] in bar.position = nil }
    }

    /// The stack deals along with the finger, and the address changes as
    /// the swipe passes halfway.
    private func follow(_ offset: CGFloat) {
        guard let index = browser.index(of: browser.selected) else { return }
        bar.position = CGFloat(index) - offset / step
        let (previous, next) = browser.neighbours
        let half = pages.view.bounds.width / 2
        let named = offset > half ? previous : offset < -half ? next : nil
        if bar.named !== named { bar.named = named }
    }
}
