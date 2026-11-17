import BrowserKit
import UIKit

/// What the bar, the grid and Browser's own pages ask of the screen.
@MainActor
protocol ScreenActions: AnyObject {
    /// The page shrinks into its card.
    func openGrid()
    /// A card grows into its page.
    func show(_ tab: Tab)
    /// The address sheet comes up.
    func edit(_ target: AddressSheetTarget)
    func showSettings()
    /// One of Browser's own pages, in a tab.
    func show(_ page: InternalPage)
    /// The address bar is being dragged: sideways between tabs, up into the grid.
    func addressBarPanned(_ pan: UIPanGestureRecognizer)
}
