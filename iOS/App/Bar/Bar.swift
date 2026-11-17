import BrowserKit
import CoreGraphics
import Observation

/// What the bar shows besides the tab itself.
@MainActor @Observable
final class Bar {
    /// Scrolling down the page shrinks the bar to the site's name alone.
    var isCollapsed = false
    /// During a swipe between tabs: where the swipe has got to, counted in
    /// tabs, for the stack to deal along with it. Nil at rest.
    var position: CGFloat?
    /// During a swipe between tabs, once past halfway: the tab it is
    /// heading for, whose name the address bar shows.
    var named: Tab?
}
