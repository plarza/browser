import SwiftUI
import UIKit

/// One move: a number a finger drags and the spring carries on, and the
/// layers placed by it. Opening the grid, the address sheet, a swipe
/// between tabs, a swipe back: each is one of these.
///
/// The spring runs in Core Animation, in the render server, so nothing the
/// app is busy with stutters it. Every property a move places is linear in
/// its number, so the spring's own interpolation of them is exact, and a
/// marker riding the same spring says where the move has got to when a
/// finger takes hold of it midway.
@MainActor
final class Move {
    /// The one spring every move uses: quick and settled, very little bounce.
    static let duration = 0.34, bounce = 0.08
    private static let spring = Spring(duration: duration, bounce: bounce)

    /// The same spring for what SwiftUI moves, so it keeps step. `velocity`
    /// is the finger's, as a fraction of the way left to go per second.
    static func animation(velocity: CGFloat = 0) -> Animation {
        .interpolatingSpring(duration: duration, bounce: bounce, initialVelocity: velocity)
    }

    /// Where the move is, or where its spring is taking it.
    private(set) var value: CGFloat
    /// A finger has it.
    var isHeld = false

    private let place: (CGFloat) -> Void
    private let moved: () -> [UIView]
    private let marker = UIView()
    private var spring: (from: CGFloat, to: CGFloat, velocity: CGFloat, began: CFTimeInterval)?
    /// Each spring's number: one's end counts only if no other began since.
    private var springs = 0

    /// `place` puts every layer where it is at a value; `moved` are the
    /// views it places, whose springs stop when a finger takes over.
    init(in host: UIView, at value: CGFloat = 0, moving moved: @escaping () -> [UIView], place: @escaping (CGFloat) -> Void) {
        self.value = value
        self.moved = moved
        self.place = place
        marker.isUserInteractionEnabled = false
        marker.center.x = value
        host.addSubview(marker)
    }

    var isMoving: Bool { isHeld || spring != nil }

    /// Where it shows right now, mid-spring included.
    var shown: CGFloat {
        guard spring != nil, let showing = marker.layer.presentation() else { return value }
        return showing.position.x
    }

    /// How fast the spring is carrying it right now, per second.
    private var speed: CGFloat {
        guard let spring else { return 0 }
        return Move.spring.velocity(target: spring.to - spring.from, initialVelocity: spring.velocity, time: CACurrentMediaTime() - spring.began)
    }

    /// Put there now. Whatever spring was carrying it lets go.
    func set(_ value: CGFloat) {
        stop()
        self.value = value
        marker.center.x = value
        place(value)
    }

    /// A finger takes hold, wherever the move has got to.
    @discardableResult
    func hold() -> CGFloat {
        let shown = shown
        isHeld = true
        set(shown)
        return shown
    }

    /// Carried to `target` by the spring, from wherever it shows now, at
    /// `velocity` (the finger's, per second) or the speed it already has.
    func spring(to target: CGFloat, velocity: CGFloat? = nil, then done: (() -> Void)? = nil) {
        let velocity = velocity ?? speed
        let from = shown
        isHeld = false
        set(from)
        guard abs(target - from) > 0.0001 else {
            set(target)
            done?()
            return
        }
        springs += 1
        let number = springs
        spring = (from, target, velocity, CACurrentMediaTime())
        value = target
        UIView.animate(springDuration: Move.duration, bounce: Move.bounce, initialSpringVelocity: velocity / (target - from),
                       delay: 0, options: .allowUserInteraction) {
            marker.center.x = target
            place(target)
        }
        // Core Animation runs a spring on long after there is anything left
        // to see. The move is over when the eye says so.
        let arrival = Move.arrival(over: target - from, velocity: velocity)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(arrival))
            guard let self, springs == number else { return }
            spring = nil
            done?()
        }
    }

    /// How long the spring takes to all but arrive: within a five-hundredth
    /// of the way, and no longer moving to speak of.
    private static func arrival(over distance: CGFloat, velocity: CGFloat) -> TimeInterval {
        var time = duration / 2
        while time < 2 {
            let left = spring.value(target: distance, initialVelocity: velocity, time: time) - distance
            let speed = spring.velocity(target: distance, initialVelocity: velocity, time: time)
            if abs(left) < abs(distance) / 500, abs(speed) < abs(distance) / 20 { break }
            time += 1 / 120
        }
        return time
    }

    private func stop() {
        guard spring != nil else { return }
        spring = nil
        springs += 1
        marker.layer.removeAllAnimations()
        for view in moved() { view.layer.removeAllAnimations() }
    }
}
