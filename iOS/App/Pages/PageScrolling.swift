import UIKit
import WebKit

/// What scrolling the page does: down shrinks the bar to the site's name;
/// back up, or reaching the top, brings it back.
@MainActor
final class PageScrolling {
    private let bar: Bar
    private let moved: () -> Void
    private weak var watched: WKWebView?
    private var observation: NSKeyValueObservation?
    /// Where the page was when the bar last changed, or last turned round.
    private var mark: CGFloat = 0
    /// A finger has scrolled this page since it was shown.
    private var touched = false

    init(bar: Bar, moved: @escaping () -> Void) {
        self.bar = bar
        self.moved = moved
    }

    var isScrolling: Bool {
        guard let scroll = watched?.scrollView else { return false }
        return scroll.isDragging || scroll.isDecelerating
    }

    func watch(_ webView: WKWebView) {
        guard webView !== watched else { return }
        watched = webView
        touched = false
        let scroll = webView.scrollView
        // A page that loaded while hidden starts at 0, under the clock,
        // where WebKit puts one loaded on screen below it.
        let top = webView.obscuredContentInsets.top
        if scroll.contentOffset.y == 0, top > 0 { scroll.contentOffset.y = -top }
        mark = scroll.contentOffset.y
        observation = scroll.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
    }

    private func scrolled() {
        guard let webView = watched else { return }
        let scroll = webView.scrollView
        // WebKit can put a page that loaded hidden back to 0 a moment after
        // it shows; until a finger moves it, its top is below the clock.
        let top = webView.obscuredContentInsets.top
        if scroll.isTracking { touched = true }
        if !touched, scroll.contentOffset.y == 0, top > 0 {
            scroll.contentOffset.y = -top
            return
        }
        moved()
        let y = scroll.contentOffset.y
        guard scroll.isTracking || scroll.isDecelerating else {
            mark = y
            return
        }
        let start = -max(scroll.adjustedContentInset.top, top)
        let travel = y - mark
        if y <= start + 8 {
            mark = y
            bar.isCollapsed = false
        } else if abs(travel) > 14 {
            mark = y
            bar.isCollapsed = travel > 0
        }
    }
}
