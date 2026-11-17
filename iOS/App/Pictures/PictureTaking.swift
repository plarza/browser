import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Sees every touch on the page lift, without taking any of them.
final class TouchWatcher: UIGestureRecognizer {
    private let lifted: () -> Void

    init(lifted: @escaping () -> Void) {
        self.lifted = lifted
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesEnded = false
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lifted()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
}

/// Decides when the page's picture is taken. Drawing a page into a picture
/// costs several milliseconds on the main thread, so it happens only when
/// nothing moves: a page coming to rest, finishing loading, coming on
/// screen, or just touched. Never as a move starts.
@MainActor
final class PictureTaking {
    /// Nothing is moving and the page is on screen: a picture can be taken.
    private let isStill: () -> Bool
    private let take: () -> Void
    private var waiting: Task<Void, Never>?

    init(isStill: @escaping () -> Bool, take: @escaping () -> Void) {
        self.isStill = isStill
        self.take = take
    }

    /// The page moved: its picture is taken once it has come to rest.
    func moved() {
        wait(.milliseconds(150))
    }

    /// The page changed without moving (it is loading, or just came on
    /// screen): its picture is taken soon, and no more often than that.
    func changed() {
        if waiting == nil { wait(.milliseconds(500)) }
    }

    private func wait(_ time: Duration) {
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: time)
            while !Task.isCancelled, let self {
                if isStill() {
                    waiting = nil
                    return take()
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
