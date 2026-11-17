import AppKit

/// Animates a layer property from its current value, the way a view's own
/// animator would: short and eased.
@MainActor
enum Motion {
    static let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    static func set(_ layer: CALayer?, _ key: String, _ value: Any?, duration: CFTimeInterval = 0.18) {
        guard let layer else { return }
        let from = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        layer.setValue(value, forKeyPath: key)
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = ease
        layer.add(animation, forKey: key)
    }
}

extension CATransaction {
    /// Layer changes made at once, or over `duration` when given.
    static func run(duration: CFTimeInterval? = nil, _ changes: () -> Void) {
        begin()
        if let duration { setAnimationDuration(duration) } else { setDisableActions(true) }
        changes()
        commit()
    }
}
