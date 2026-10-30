#if os(macOS)
import AppKit
public typealias PlatformView = NSView
#else
import UIKit
public typealias PlatformView = UIView
#endif
import WebKit

/// What shows a tab: its web view, and over it whatever the last page left
/// behind (the web view a wipe replaced, a picture from a swipe) until the
/// next page has drawn, as Safari keeps a page up until the next one paints.
/// What's left behind is frozen: it takes no clicks or touches.
@MainActor
public final class PageView: PlatformView {
    private var leftBehind: [PlatformView] = []
    private var timeout: Task<Void, Never>?

    /// `webView` underneath everything; `old`, the one it replaces, stays
    /// on top until `webView` draws. Without `old`, everything goes now.
    func show(_ webView: WKWebView, replacing old: WKWebView?) {
        fill(webView)
        #if os(macOS)
        addSubview(webView, positioned: .below, relativeTo: nil)
        #else
        insertSubview(webView, at: 0)
        #endif
        guard let old, old.superview === self else {
            old?.removeFromSuperview()
            clear()
            return
        }
        old.pauseAllMediaPlayback(completionHandler: nil)
        leftBehind.append(old)
    }

    /// `view` over the page until the next page draws: a swipe's picture of
    /// where it's going, so the page it left never shows again.
    public func hold(_ view: PlatformView) {
        fill(view)
        addSubview(view)
        leftBehind.append(view)
    }

    /// The new page committed. Most draw at once; one that doesn't gets
    /// three seconds, as Safari gives a swipe's picture.
    func committed() {
        guard !leftBehind.isEmpty else { return }
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.drew() }
        }
    }

    /// The new page drew something: what was left behind fades away.
    func drew() {
        timeout?.cancel()
        // Only the top one fades; anything under it would show through.
        guard let top = leftBehind.popLast() else { return }
        clear()
        #if os(macOS)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            top.animator().alphaValue = 0
        } completionHandler: {
            top.removeFromSuperview()
        }
        #else
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            top.alpha = 0
        } completion: { _ in
            top.removeFromSuperview()
        }
        #endif
    }

    /// Everything left behind goes at once.
    func clear() {
        timeout?.cancel()
        for view in leftBehind { view.removeFromSuperview() }
        leftBehind = []
    }

    private func fill(_ view: PlatformView) {
        view.frame = bounds
        #if os(macOS)
        view.autoresizingMask = [.width, .height]
        #else
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
    }

    #if os(macOS)
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard leftBehind.isEmpty else { return frame.contains(point) ? self : nil }
        return super.hitTest(point)
    }
    #else
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard leftBehind.isEmpty else { return self.point(inside: point, with: event) ? self : nil }
        return super.hitTest(point, with: event)
    }
    #endif
}
