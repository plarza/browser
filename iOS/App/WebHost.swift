import BrowserKit
import SwiftUI
import WebKit

/// Holds the tabs' web views, showing the selected one. Pages stay put
/// when hidden rather than coming off screen and back: WebKit keeps a page's
/// place, and its picture, only while it's in the window.
struct WebHost: UIViewRepresentable {
    let tab: Tab
    /// The tab's web view now: a wipe swaps it, and this is what tells
    /// SwiftUI the page changed.
    let webView: WKWebView
    @Environment(Browser.self) private var browser

    func makeUIView(context: Context) -> PageView {
        let view = PageView()
        view.browser = browser
        return view
    }

    func updateUIView(_ view: PageView, context: Context) {
        view.browser = browser
        view.show(tab, keeping: browser.tabs.map(\.webView))
    }
}

/// The page, edge swipes for Back and Forward, pull to reload, and the
/// scrolling that shrinks the bar.
final class PageView: UIView {
    /// The bar's height over the page, above the home indicator.
    static let barHeight: CGFloat = 58
    weak var browser: Browser?
    private weak var tab: Tab?
    private weak var webView: WKWebView?
    private var scrolling: NSKeyValueObservation?
    private var lastOffset: CGFloat = 0
    /// The page showing has been scrolled by a finger since it was shown.
    private var touched = false

    private lazy var backEdge = edge(.left)
    private lazy var forwardEdge = edge(.right)
    /// The page as it was when the swipe began, slid along with the finger.
    private var sliding: UIView?
    /// Left behind after a swipe, until the next page is on screen.
    private var cover: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        addGestureRecognizer(backEdge)
        addGestureRecognizer(forwardEdge)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyInsets()
    }

    /// Below the clock, and with the page's end able to scroll up clear of
    /// the bar. WebKit is told what's covered and keeps the page's place
    /// against those edges itself.
    private func applyInsets() {
        // The window's: SwiftUI hands a view that ignores the safe area none.
        guard let safe = window?.safeAreaInsets else { return }
        let insets = UIEdgeInsets(top: safe.top, left: 0, bottom: safe.bottom + Self.barHeight, right: 0)
        for case let page as WKWebView in subviews {
            if page.obscuredContentInsets != insets { page.obscuredContentInsets = insets }
            // Room under the page's end, so it scrolls up past the bar.
            if page.scrollView.contentInset.bottom != insets.bottom {
                page.scrollView.contentInset.bottom = insets.bottom
                page.scrollView.verticalScrollIndicatorInsets = insets
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyInsets()
    }

    private func edge(_ edges: UIRectEdge) -> UIScreenEdgePanGestureRecognizer {
        let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        pan.edges = edges
        return pan
    }

    /// `live`: every tab's web view now; any other here belonged to a
    /// closed tab or was replaced by a wipe, and goes.
    func show(_ tab: Tab, keeping live: [WKWebView]) {
        for case let page as WKWebView in subviews where !live.contains(page) { page.removeFromSuperview() }
        self.tab = tab
        let view = tab.webView
        if view.superview !== self { attach(view) }
        for case let page as WKWebView in subviews { page.isHidden = page !== view }
        guard view !== webView else { return }
        // A page that loaded while hidden starts at 0, under the clock,
        // where WebKit places one loaded on screen below it.
        let top = view.obscuredContentInsets.top
        if view.scrollView.contentOffset.y == 0, top > 0 { view.scrollView.contentOffset.y = -top }
        touched = false
        webView = view
        lastOffset = view.scrollView.contentOffset.y
        scrolling = view.scrollView.observe(\.contentOffset) { [weak self] scroll, _ in
            MainActor.assumeIsolated { self?.scrolled(scroll) }
        }
        // The page that took over from a swipe: the old picture goes.
        if let cover {
            self.cover = nil
            UIView.animate(withDuration: 0.25, delay: 0.15) { cover.alpha = 0 } completion: { _ in cover.removeFromSuperview() }
        }
    }

    private func attach(_ view: WKWebView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(view, at: 0)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        view.isFindInteractionEnabled = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.keyboardDismissMode = .interactive
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            refresh?.endRefreshing()
            self?.tab?.reload()
        }, for: .valueChanged)
        view.scrollView.refreshControl = refresh
        applyInsets()
    }

    /// Down the page shrinks the bar to the site's name; back up, or at the
    /// top, brings it back.
    private func scrolled(_ scroll: UIScrollView) {
        // WebKit can put a page that loaded hidden back to 0 a moment after
        // it shows; until a finger moves it, its top is below the clock.
        let top = webView?.obscuredContentInsets.top ?? 0
        if scroll.isTracking { touched = true }
        if !touched, scroll.contentOffset.y == 0, top > 0 {
            scroll.contentOffset.y = -top
            return
        }
        guard let browser, scroll.isTracking || scroll.isDecelerating else {
            lastOffset = scroll.contentOffset.y
            return
        }
        let y = scroll.contentOffset.y, start = -max(scroll.adjustedContentInset.top, top)
        let delta = y - lastOffset
        if y <= start + 8 {
            if browser.barCollapsed { withAnimation(Motion.spring()) { browser.barCollapsed = false } }
            lastOffset = y
        } else if delta > 14 {
            if !browser.barCollapsed { withAnimation(Motion.spring()) { browser.barCollapsed = true } }
            lastOffset = y
        } else if delta < -14 {
            if browser.barCollapsed { withAnimation(Motion.spring()) { browser.barCollapsed = false } }
            lastOffset = y
        }
    }

    // MARK: Back and forward

    @objc private func swiped(_ pan: UIScreenEdgePanGestureRecognizer) {
        guard let tab, let webView else { return }
        let back = pan === backEdge
        guard back ? tab.canGoBack : tab.canGoForward else { return }
        let x = pan.translation(in: self).x
        let width = bounds.width
        switch pan.state {
        case .began:
            guard let picture = webView.snapshotView(afterScreenUpdates: false) else { return }
            picture.frame = bounds
            picture.layer.shadowColor = UIColor.black.cgColor
            picture.layer.shadowOpacity = 0.18
            picture.layer.shadowRadius = 14
            addSubview(picture)
            sliding = picture
            webView.alpha = 0
        case .changed:
            sliding?.transform = CGAffineTransform(translationX: back ? max(0, x) : min(0, x), y: 0)
        case .ended, .cancelled:
            guard let picture = sliding else { return }
            sliding = nil
            let velocity = pan.velocity(in: self).x
            let done = pan.state == .ended && (back ? x > width * 0.35 || velocity > 600 : -x > width * 0.35 || velocity < -600)
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
                picture.transform = done ? CGAffineTransform(translationX: back ? width : -width, y: 0) : .identity
            } completion: { _ in
                picture.removeFromSuperview()
                webView.alpha = 1
            }
            guard done else { return }
            // A plain backdrop until the page loads into its new identity.
            let blank = UIView(frame: bounds)
            blank.backgroundColor = .systemBackground
            blank.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            insertSubview(blank, belowSubview: picture)
            cover = blank
            if back { tab.goBack() } else { tab.goForward() }
        default:
            break
        }
    }
}
