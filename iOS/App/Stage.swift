import BrowserKit
import SwiftUI
import UIKit
import WebKit

/// The page and everything that moves it, in UIKit, so every move is a
/// Core Animation one that the render server runs off the main thread, as
/// Safari's are. Each uses the same SwiftUI spring as the bar and the grid,
/// handed over by `context.animate`, so they keep step.
///
/// `pages`, under the grid, holds the live pages and slides them for
/// swipes. `flyer`, over the grid, carries a picture of the page into its
/// card and back, and behind the address sheet: WebKit moves a page's
/// scroll position when it sees its view scaled, so the live page never is.
@MainActor
final class Stage {
    let pages: Pages
    let flyer = Flyer()
    private weak var browser: Browser?
    /// Where the flyer was last put, to start the next move from.
    private var placed: (grid: CGFloat, edit: CGFloat) = (0, 0)
    /// Each move's number: a move's end counts only if no other began since.
    private var move = 0

    init(browser: Browser) {
        self.browser = browser
        pages = Pages(browser: browser)
    }

    /// The grid and the address sheet, at `grid` and `edit` (each 0 to 1).
    func update(grid: CGFloat, edit: CGFloat, animated: Bool, animate: (@escaping () -> Void, @escaping () -> Void) -> Void) {
        guard let browser, (grid, edit) != placed else { return }
        let card = browser.selected.flatMap { browser.cardFrames[$0.id] }
        if !flyer.isFlying {
            // Taking off: from the page, its exact picture; from the grid,
            // its card's.
            let fromPage = placed == (0, 0)
            if fromPage, let tab = browser.selected { browser.capture(tab) }
            flyer.takeOff(copy: fromPage ? pages.copy() : nil, image: browser.selected.flatMap { browser.picture($0) })
            flyer.place(at: placed, card: card)
            pages.alpha = 0
            DispatchQueue.main.async { browser.landed = false }
        }
        placed = (grid, edit)
        move += 1
        let move = move
        if !animated { flyer.stop() }
        animate({ self.flyer.place(at: (grid, edit), card: card) }) { [weak self] in
            guard let self, self.move == move else { return }
            self.landed()
        }
    }

    /// At rest on the page, the live page shows again; on its card, the
    /// card does, and the flyer goes once the card is showing.
    private func landed() {
        if placed == (0, 0) {
            pages.alpha = 1
            flyer.land()
        } else if placed.grid == 1 {
            browser?.landed = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                if self.placed.grid == 1, self.browser?.landed == true { self.flyer.land() }
            }
        }
    }
}

/// A page as a picture: its last snapshot, or a live copy of the screen.
final class Picture: UIView {
    private let image = UIImageView()
    private var copy: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        clipsToBounds = true
        image.contentMode = .scaleAspectFill
        image.frame = bounds
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(image)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ picture: UIImage?, copy: UIView? = nil) {
        image.image = picture
        guard copy !== self.copy else { return }
        if self.copy?.superview === self { self.copy?.removeFromSuperview() }
        self.copy = copy
        if let copy {
            copy.frame = bounds
            copy.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(copy)
        }
    }
}

/// A picture of the page in flight: scaled to its card's width, cut to its
/// height, corners rounding as it goes. Every property it moves is linear
/// in the progress, so Core Animation's interpolation of them is exact.
final class Flyer: UIView {
    private let frameView = UIView()
    private let picture = Picture()
    private(set) var isFlying = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        frameView.layer.anchorPoint = .zero
        frameView.clipsToBounds = true
        frameView.layer.cornerCurve = .continuous
        frameView.isHidden = true
        frameView.addSubview(picture)
        addSubview(frameView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func takeOff(copy: UIView?, image: UIImage?) {
        isFlying = true
        picture.frame = CGRect(origin: .zero, size: Screen.bounds.size)
        picture.show(image, copy: copy)
        frameView.isHidden = false
    }

    func land() {
        isFlying = false
        frameView.isHidden = true
        picture.show(nil)
    }

    /// A finger moves it now: whatever spring was moving it lets go.
    func stop() { frameView.layer.removeAllAnimations() }

    /// At `grid` between the page (0) and its card (1), and `edit` stepped
    /// back behind the address sheet. With no card it shrinks to the
    /// middle and fades.
    func place(at state: (grid: CGFloat, edit: CGFloat), card: CGRect?) {
        let screen = Screen.bounds
        let (p, e) = state
        let target = card ?? screen.insetBy(dx: screen.width * 0.1, dy: screen.height * 0.1)
        let fit = screen.width > 0 ? target.width / screen.width : 1
        var scale = 1 + (fit - 1) * p
        var origin = CGPoint(x: target.minX * p, y: target.minY * p)
        let height = screen.height + (target.height / fit - screen.height) * p
        let zoomRadius = Screen.radius + (TabCard.radius / fit - Screen.radius) * p
        // Arc's sheet: the page steps back, from its top, into a card above it.
        let back = 1 - 0.08 * e
        origin = CGPoint(x: screen.midX + (origin.x - screen.midX) * back, y: origin.y * back + 36 * e)
        scale *= back
        frameView.bounds = CGRect(x: 0, y: 0, width: screen.width, height: height)
        frameView.center = origin
        frameView.transform = CGAffineTransform(scaleX: scale, y: scale)
        frameView.layer.cornerRadius = zoomRadius + (34 - zoomRadius) * e
        frameView.alpha = card == nil ? 1 - p : 1
    }
}

/// The selected tab's page; while the address bar is dragged sideways, the
/// pictures of the tabs either side; while an edge is, the page before or
/// after. Every tab's page stays in the window once shown, the selected one
/// showing: WebKit keeps a page's place and drawing only while it's there.
final class Pages: UIView {
    /// The bar's height over the page, above the home indicator.
    static let barHeight: CGFloat = 58
    static let gap: CGFloat = 12

    private weak var browser: Browser?
    /// Slides with the address bar, the neighbours' pictures beside the page.
    private let slider = UIView()
    /// Slides with an edge swipe.
    private let page = UIView()
    private let before = Picture(), after = Picture()
    /// Browser's own pages, and what a tab with nowhere to go shows.
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var hosting: String?
    private weak var shown: Tab?
    /// The page that was showing, as it was, for the side it went to.
    private var left: (tab: UUID, copy: UIView)?

    private weak var scrolledView: WKWebView?
    private var scrolling: NSKeyValueObservation?
    private var lastOffset: CGFloat = 0
    /// The page showing has been scrolled by a finger since it was shown.
    private var touched = false
    private var settle: Task<Void, Never>?

    private lazy var backEdge = edge(.left)
    private lazy var forwardEdge = edge(.right)
    private var swipe: (back: Bool, target: Picture)?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        for view in [slider, page] {
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.frame = bounds
        }
        addSubview(slider)
        slider.addSubview(before)
        slider.addSubview(after)
        slider.addSubview(page)
        host.view.backgroundColor = .clear
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.isHidden = true
        // Clear of the bar, search field and all.
        host.additionalSafeAreaInsets.bottom = Self.barHeight
        page.addSubview(host.view)
        addGestureRecognizer(backEdge)
        addGestureRecognizer(forwardEdge)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width + Self.gap
        before.frame = bounds.offsetBy(dx: -width, dy: 0)
        after.frame = bounds.offsetBy(dx: width, dy: 0)
        host.view.frame = page.bounds
        for case let tab as PageView in page.subviews {
            for case let web as WKWebView in tab.subviews { inset(web) }
        }
    }

    /// Browser's own pages are a view controller's, so they get their
    /// margins and safe area as any screen does.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard host.parent == nil, let parent = sequence(first: next, next: { $0?.next }).first(where: { $0 is UIViewController }) as? UIViewController else { return }
        parent.addChild(host)
        host.didMove(toParent: parent)
    }

    // MARK: Showing

    /// The selected tab's page, with its neighbours' pictures beside it.
    func update() {
        guard let browser else { return }
        let tab = browser.selected
        let views = Set(browser.tabs.map { ObjectIdentifier($0.view) })
        for case let view as PageView in page.subviews where !views.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        if let tab, tab.view.superview !== page {
            tab.view.frame = page.bounds
            tab.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            page.insertSubview(tab.view, belowSubview: host.view)
        }
        if tab !== shown { switched(to: tab) }
        let hosted: String? = if let tab { tab.internalPage ?? (tab.url == nil ? "" : nil) } else { "" }
        for case let view as PageView in page.subviews { view.isHidden = view !== tab?.view || hosted != nil }
        host(hosted)
        if let tab { prepare(tab.webView); observe(tab.webView) }

        let (previous, next) = browser.neighbours
        for (picture, tab) in [(before, previous), (after, next)] {
            picture.show(tab.flatMap { browser.picture($0) }, copy: tab?.id == left?.tab ? left?.copy : nil)
        }
    }

    /// The tab coming in shows its picture until its page has had a moment
    /// to draw; the one going is kept as it was, for the side it's on.
    private func switched(to tab: Tab?) {
        if let old = shown, !old.view.isHidden, let copy = old.view.snapshotView(afterScreenUpdates: false) {
            left = (old.id, copy)
        }
        shown = tab
        touched = false
        captureSoon()
        guard let browser, let tab, let image = browser.picture(tab) else { return }
        let cover = Picture(frame: page.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.show(image)
        cover.isUserInteractionEnabled = false
        page.addSubview(cover)
        UIView.animate(withDuration: 0.2, delay: 0.25, options: .allowUserInteraction) { cover.alpha = 0 } completion: { _ in
            cover.removeFromSuperview()
        }
    }

    /// `page`: Browser's own page by name, "" for a tab with nowhere to go,
    /// nil for a web page.
    private func host(_ name: String?) {
        guard name != hosting else { return }
        hosting = name
        host.view.isHidden = name == nil
        guard let name, let browser else { host.rootView = AnyView(EmptyView()); return }
        host.rootView = name.isEmpty ? AnyView(NewTabPage()) : AnyView(InternalPageView(page: name).environment(browser))
    }

    /// Slid sideways by `offset` with the address bar.
    func slide(_ offset: CGFloat, animated: Bool) {
        if !animated { slider.layer.removeAllAnimations() }
        slider.transform = CGAffineTransform(translationX: offset, y: 0)
    }

    /// A copy of the page as it shows now, to fly in its place.
    func copy() -> UIView? { page.snapshotView(afterScreenUpdates: false) }

    /// The page as it shows now, for the grid, the tab stack and swipes.
    func render() -> UIImage? {
        guard window != nil, alpha == 1, !page.bounds.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: page.bounds, format: format).image { _ in
            page.drawHierarchy(in: page.bounds, afterScreenUpdates: false)
        }
    }

    // MARK: Web views

    /// Once per web view: the find bar, pull to reload, and its insets.
    func prepare(_ web: WKWebView) {
        guard web.scrollView.refreshControl == nil else { return }
        web.isFindInteractionEnabled = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.keyboardDismissMode = .interactive
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            refresh?.endRefreshing()
            self?.browser?.selected?.reload()
        }, for: .valueChanged)
        web.scrollView.refreshControl = refresh
        inset(web)
    }

    /// Below the clock, and with the page's end able to scroll up clear of
    /// the bar. WebKit is told what's covered and keeps the page's place
    /// against those edges itself.
    private func inset(_ web: WKWebView) {
        // The window's: SwiftUI hands a view that ignores the safe area none.
        guard let safe = (window ?? Screen.window)?.safeAreaInsets else { return }
        let insets = UIEdgeInsets(top: safe.top, left: 0, bottom: safe.bottom + Self.barHeight, right: 0)
        if web.obscuredContentInsets != insets { web.obscuredContentInsets = insets }
        if web.scrollView.contentInset.bottom != insets.bottom {
            web.scrollView.contentInset.bottom = insets.bottom
            web.scrollView.verticalScrollIndicatorInsets = insets
        }
    }

    private func observe(_ web: WKWebView) {
        guard web !== scrolledView else { return }
        scrolledView = web
        // A page that loaded while hidden starts at 0, under the clock,
        // where WebKit places one loaded on screen below it.
        let top = web.obscuredContentInsets.top
        if web.scrollView.contentOffset.y == 0, top > 0 { web.scrollView.contentOffset.y = -top }
        lastOffset = web.scrollView.contentOffset.y
        scrolling = web.scrollView.observe(\.contentOffset) { [weak self] scroll, _ in
            MainActor.assumeIsolated { self?.scrolled(scroll) }
        }
    }

    /// The selected page's picture, once it has been still for a moment.
    func captureSoon() {
        settle?.cancel()
        settle = Task { [weak browser] in
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled, let browser, let tab = browser.selected { browser.capture(tab) }
        }
    }

    /// Down the page shrinks the bar to the site's name; back up, or at the
    /// top, brings it back. Once the page comes to rest, its picture is
    /// taken, so a swipe or the grid never waits for one.
    private func scrolled(_ scroll: UIScrollView) {
        guard let browser else { return }
        // WebKit can put a page that loaded hidden back to 0 a moment after
        // it shows; until a finger moves it, its top is below the clock.
        let top = scrolledView?.obscuredContentInsets.top ?? 0
        if scroll.isTracking { touched = true }
        if !touched, scroll.contentOffset.y == 0, top > 0 {
            scroll.contentOffset.y = -top
            return
        }
        captureSoon()
        guard scroll.isTracking || scroll.isDecelerating else {
            lastOffset = scroll.contentOffset.y
            return
        }
        let y = scroll.contentOffset.y, start = -max(scroll.adjustedContentInset.top, top)
        let delta = y - lastOffset
        let collapse: Bool? = y <= start + 8 ? false : delta > 14 ? true : delta < -14 ? false : nil
        if y <= start + 8 || abs(delta) > 14 { lastOffset = y }
        if let collapse, collapse != browser.barCollapsed {
            withAnimation(Motion.spring()) { browser.barCollapsed = collapse }
        }
    }

    // MARK: Back and forward

    /// Safari's: going back, the page slides off to the right, the page
    /// before coming out from under it; going forward, the page after
    /// slides in over it from the right.
    private func edge(_ edges: UIRectEdge) -> UIScreenEdgePanGestureRecognizer {
        let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        pan.edges = edges
        return pan
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let tab = browser?.selected, alpha == 1, swipe == nil else { return false }
        if gesture === backEdge { return tab.canGoBack }
        if gesture === forwardEdge { return tab.canGoForward }
        return true
    }

    @objc private func swiped(_ pan: UIScreenEdgePanGestureRecognizer) {
        let back = pan === backEdge
        let x = pan.translation(in: self).x, speed = pan.velocity(in: self).x
        switch pan.state {
        case .began: beginSwipe(back: back)
        case .changed: follow(back ? x : -x)
        case .ended: endSwipe(at: back ? x : -x, speed: back ? speed : -speed)
        case .cancelled, .failed: endSwipe(at: 0, speed: 0)
        default: break
        }
    }

    func beginSwipe(back: Bool) {
        guard let browser, let tab = browser.selected else { return }
        let target = Picture(frame: bounds)
        target.show(browser.picture(tab, at: tab.index + (back ? -1 : 1)))
        if back { slider.insertSubview(target, belowSubview: page) } else { slider.addSubview(target) }
        let top = back ? page : target
        top.layer.shadowColor = UIColor.black.cgColor
        top.layer.shadowOpacity = 0.2
        top.layer.shadowRadius = 12
        top.layer.shadowPath = UIBezierPath(rect: bounds).cgPath
        swipe = (back, target)
        follow(0)
    }

    /// The finger let go `x` points along, moving at `speed`: on to the
    /// page it was heading for if it's past a third of the way (or flung
    /// there), at the finger's speed; or back.
    func endSwipe(at x: CGFloat, speed: CGFloat) {
        guard let swipe, let tab = browser?.selected else { return }
        let width = bounds.width
        let x = min(width, max(0, x))
        let done = x + speed * 0.15 > width / 3
        let remaining = (done ? width : 0) - x
        UIView.animate(Motion.spring(velocity: remaining == 0 ? 0 : speed / remaining)) {
            self.follow(done ? width : 0)
        } completion: { [weak self, weak tab] in
            guard let self else { return }
            self.swipe = nil
            self.page.transform = .identity
            self.page.layer.shadowOpacity = 0
            swipe.target.transform = .identity
            swipe.target.layer.shadowOpacity = 0
            swipe.target.removeFromSuperview()
            guard done, let tab else { return }
            // The picture stays over the page until the next one draws.
            tab.view.hold(swipe.target)
            if swipe.back { tab.goBack() } else { tab.goForward() }
        }
    }

    /// The swipe `x` points along: the top page moves with the finger, the
    /// one under it a third as far, as iOS's own pages do.
    func follow(_ x: CGFloat) {
        guard let (back, target) = swipe else { return }
        let width = bounds.width, x = min(width, max(0, x))
        if back {
            page.transform = CGAffineTransform(translationX: x, y: 0)
            target.transform = CGAffineTransform(translationX: -(width - x) / 3, y: 0)
        } else {
            target.transform = CGAffineTransform(translationX: width - x, y: 0)
            page.transform = CGAffineTransform(translationX: -x / 3, y: 0)
        }
    }
}

/// The live pages, under the grid.
struct PagesLayer: UIViewRepresentable {
    @Environment(Browser.self) private var browser
    /// What it shows; read here so SwiftUI updates it when they change.
    let revision: Int
    let selected: Tab?
    let offset: CGFloat

    func makeUIView(context: Context) -> Pages { browser.stage.pages }

    func updateUIView(_ pages: Pages, context: Context) {
        pages.update()
        let animated = context.transaction.animation != nil
        context.animate { pages.slide(offset, animated: animated) }
    }
}

/// The flyer, over the grid.
struct FlyerLayer: UIViewRepresentable {
    @Environment(Browser.self) private var browser
    let grid: CGFloat
    let edit: CGFloat

    func makeUIView(context: Context) -> Flyer { browser.stage.flyer }

    func updateUIView(_ flyer: Flyer, context: Context) {
        browser.stage.update(grid: grid, edit: edit, animated: context.transaction.animation != nil) { changes, done in
            context.animate(changes: changes, completion: done)
        }
    }
}

enum Screen {
    static var window: UIWindow? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow
    }

    static var bounds: CGRect {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds ?? .zero
    }

    /// The screen's own corners, so the page leaves and lands as the glass does.
    static var radius: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.value(forKey: "_displayCornerRadius") as? CGFloat ?? 44
    }
}
