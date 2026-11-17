import UIKit

/// Opening the grid: the page shrinks into its card, the grid fades up
/// behind it, and the bar sinks and fades. Coming back, it grows out of
/// the card. Dragging the address bar up does it under the finger.
@MainActor
final class GridOpening {
    /// How far up the finger goes to take the page all the way into its card.
    private static let pull: CGFloat = 320

    private let shrunk: ShrunkPage
    private let grid: UIView
    private let gridBar: UIView
    private let bar: UIView
    private let frost: Frost
    private var grabbedAt: CGFloat = 0

    /// 0 with the page filling the screen, 1 with it in its card.
    let move: Move

    init(in host: UIView, shrunk: ShrunkPage, grid: UIView, gridBar: UIView, bar: UIView, frost: Frost) {
        self.shrunk = shrunk
        self.grid = grid
        self.gridBar = gridBar
        self.bar = bar
        self.frost = frost
        move = Move(in: host, moving: { shrunk.moved + [grid, gridBar, bar, frost.moved] }) { open in
            shrunk.place(open)
            grid.alpha = open
            gridBar.alpha = open
            gridBar.transform = CGAffineTransform(translationX: 0, y: 40 * (1 - open))
            bar.alpha = 1 - open
            bar.transform = CGAffineTransform(translationX: 0, y: 40 * open)
            frost.strength = 1 - open
        }
    }

    var isOpen: Bool { move.value > 0 || move.isMoving }

    func began() {
        grabbedAt = move.hold()
    }

    /// The finger is `up` points above where it took hold.
    func changed(by up: CGFloat) {
        move.set(min(1, max(0, grabbedAt + up / GridOpening.pull)))
    }

    /// The finger let go, moving up at `speed`: on into the grid, or back,
    /// at the finger's speed.
    func ended(speed: CGFloat, then landed: @escaping () -> Void) {
        let speed = speed / GridOpening.pull
        move.spring(to: move.value + speed * 0.15 > 0.4 ? 1 : 0, velocity: speed, then: landed)
    }
}
