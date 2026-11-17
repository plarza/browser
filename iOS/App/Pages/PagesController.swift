import BrowserKit
import SwiftUI
import UIKit
import WebKit

/// The selected tab's page, live. Every tab's page stays in the window once
/// shown, hidden unless it is the one selected: WebKit keeps a page's place
/// and drawing only while its view is there.
///
/// Browser's own pages and the new tab page show here too, in the web
/// view's place. Beside the page sit pictures of the tabs either side, for
/// swiping between tabs.
final class PagesController: UIViewController {
    private let browser: Browser
    private let bar: Bar
    let pictures: Pictures
    /// The page is on screen: nothing stands in for it.
    private let isHome: () -> Bool

    /// Slides with the address bar: the page, and the tabs either side.
    let slider = UIView()
    /// Slides with a swipe back or forward: everything the tab shows.
    let page = UIView()
    private let before = Picture(), after = Picture()
    private let newTabPage = NewTabPageView()
    private let ownPage: UIHostingController<OwnPage>
    /// Over a page just shown again, until it has drawn.
    private var cover: Picture?

    /// The tab whose page shows.
    private var shown: Tab?
    /// The page shown before this one, exactly as it was, for the side it left by.
    private var left: (tab: UUID, copy: UIView)?

    private(set) lazy var tabSwipe = TabSwipe(pages: self, browser: browser, bar: bar)
    private(set) lazy var edgeSwipe = EdgeSwipe(pages: self, browser: browser)
    private lazy var scrolling = PageScrolling(bar: bar) { [weak self] in self?.taking.moved() }
    private lazy var taking = PictureTaking { [weak self] in self?.isStill ?? false } take: { [weak self] in self?.takePicture() }
    private var following: [Observer] = []

    init(browser: Browser, bar: Bar, pictures: Pictures, isHome: @escaping () -> Bool) {
        self.browser = browser
        self.bar = bar
        self.pictures = pictures
        self.isHome = isHome
        ownPage = UIHostingController(rootView: OwnPage(showing: nil, browser: browser))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        for view in [slider, page, newTabPage] {
            view.frame = self.view.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        view.addSubview(slider)
        slider.addSubview(before)
        slider.addSubview(after)
        slider.addSubview(page)
        page.addSubview(newTabPage)

        // A child, so Browser's own pages get their margins and safe area
        // as any screen does; clear of the bar, search field and all.
        addChild(ownPage)
        ownPage.view.frame = page.bounds
        ownPage.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        ownPage.view.isHidden = true
        ownPage.additionalSafeAreaInsets.bottom = Look.barHeight
        page.addSubview(ownPage.view)
        ownPage.didMove(toParent: self)

        edgeSwipe.install(on: view)
        // A touch can change a page without moving or loading it, and so
        // can going light or dark: its picture is taken again.
        view.addGestureRecognizer(TouchWatcher { [weak self] in self?.taking.changed() })
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (pages: PagesController, _) in pages.taking.changed() }
        following = [
            Observer { [weak self] in self?.showNeighbours() },
            Observer { [weak self] in self?.loadingChanged() },
        ]
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let step = view.bounds.width + Look.gap
        before.frame = view.bounds.offsetBy(dx: -step, dy: 0)
        after.frame = view.bounds.offsetBy(dx: step, dy: 0)
        for tab in browser.tabs { inset(tab.webView) }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        for tab in browser.tabs { inset(tab.webView) }
    }

    // MARK: Showing

    /// Shows what the selected tab shows now. The screen runs it again
    /// whenever that changes; whoever changes it mid-move runs it at once,
    /// so the change and the move land in the same frame.
    func update() {
        let tab = browser.selected
        let arriving = tab !== shown
        // The page going, exactly as it shows, before anything is swapped.
        let copy = arriving && isHome() && browser.index(of: shown) != nil ? page.snapshotView(afterScreenUpdates: false) : nil
        let from = shown

        let open = Set(browser.tabs.map { ObjectIdentifier($0.view) })
        for case let view as PageView in page.subviews where !open.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        if let tab, tab.view.superview !== page {
            tab.view.frame = page.bounds
            tab.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            page.insertSubview(tab.view, at: 0)
        }
        let isWeb = tab.map { $0.page == nil && !$0.isBlank } ?? false
        for case let view as PageView in page.subviews { view.isHidden = view !== tab?.view || !isWeb }
        newTabPage.isHidden = !(tab?.isBlank ?? false)
        show(tab?.page, in: tab)
        if let tab, isWeb {
            prepare(tab.webView)
            scrolling.watch(tab.webView)
        }

        guard arriving else { return }
        shown = tab
        bar.isCollapsed = false
        arrive(at: tab)
        if let from, let copy { left = (from.id, copy) }
        showNeighbours()
        taking.changed()
        if let from, let tab, copy != nil { tabSwipe.arrived(at: tab, from: from) }
    }

    /// A tab shown again can take a moment to draw: until it has, what
    /// stood for it stays over it, so the handover shows no change.
    private func arrive(at tab: Tab?) {
        cover?.removeFromSuperview()
        cover = nil
        guard let tab else { return }
        var standing = Picture.Content.of(tab, in: pictures)
        if let left, left.tab == tab.id {
            standing = .copy(left.copy)
            self.left = nil
        }
        switch standing {
        case .image, .copy:
            let cover = Picture(frame: page.bounds)
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.show(standing)
            page.addSubview(cover)
            self.cover = cover
            whenDrawn(tab) { [weak self] in
                guard let self, self.cover === cover else { return }
                self.cover = nil
                UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) { cover.alpha = 0 } completion: { _ in cover.removeFromSuperview() }
            }
        case .site:
            // A tab with no picture yet is only now loading: its icon and
            // host stay up until the page draws.
            guard tab.page == nil, tab.isLoading else { return }
            let waiting = Picture(frame: page.bounds)
            waiting.show(standing)
            tab.view.hold(waiting)
        case .plain:
            break
        }
    }

    /// Runs `then` once `tab`'s page has drawn what it shows now. WebKit
    /// says when (its private call, as Safari uses); a page that never
    /// answers gets a second.
    private func whenDrawn(_ tab: Tab, then: @escaping @MainActor () -> Void) {
        var done = false
        let finish: @MainActor () -> Void = {
            guard !done else { return }
            done = true
            then()
        }
        let ask = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        if tab.page == nil, !tab.isBlank, tab.webView.responds(to: ask) {
            let drawn: @convention(block) () -> Void = { MainActor.assumeIsolated(finish) }
            tab.webView.perform(ask, with: drawn)
        }
        Task {
            try? await Task.sleep(for: tab.page == nil && !tab.isBlank ? .seconds(1) : .milliseconds(50))
            finish()
        }
    }

    private func show(_ own: InternalPage?, in tab: Tab?) {
        let showing = tab.flatMap { tab in own.map { OwnPage.Showing(page: $0, tab: tab.id) } }
        ownPage.view.isHidden = showing == nil
        guard showing != ownPage.rootView.showing else { return }
        ownPage.rootView = OwnPage(showing: showing, browser: browser)
    }

    /// The tabs either side, as pictures beside the page.
    private func showNeighbours() {
        let (previous, next) = browser.neighbours
        for (picture, tab) in [(before, previous), (after, next)] {
            picture.isHidden = tab == nil
            guard let tab else { continue }
            if let left, left.tab == tab.id { picture.show(.copy(left.copy)) } else { picture.show(.of(tab, in: pictures)) }
        }
    }

    /// What stands for the page showing, for whoever takes its place while
    /// it is away: an exact copy while it is on screen.
    func standIn() -> Picture.Content {
        if isHome(), shown != nil, let copy = page.snapshotView(afterScreenUpdates: false) { return .copy(copy) }
        return shown.map { .of($0, in: pictures) } ?? .plain
    }

    /// The last picture of the tab that was showing, when it has just closed.
    func lastPicture() -> Picture.Content {
        guard let shown, let image = pictures.picture(of: shown) else { return .plain }
        return .image(image)
    }

    // MARK: Web views

    /// Once per web view, before it loads anything: the find bar, pull to
    /// reload, and what the clock and the bar cover.
    func prepare(_ webView: WKWebView) {
        guard webView.scrollView.refreshControl == nil else { return }
        webView.isFindInteractionEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh, weak webView] _ in
            guard let self, let refresh, let webView else { return }
            reload(webView, pulledBy: refresh)
        }, for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        inset(webView)
    }

    /// Pulled far enough: the page reloads once the finger has let go and
    /// it has settled back. A reload leaves the old page up until the new
    /// one draws, and by then the two are in the same place.
    private func reload(_ webView: WKWebView, pulledBy refresh: UIRefreshControl) {
        // Ended at once, so the spinner doesn't hold the page down.
        refresh.endRefreshing()
        Task { [weak self, weak webView] in
            for _ in 0 ..< 100 {
                guard let scroll = webView?.scrollView else { return }
                guard scroll.isTracking || scroll.isDecelerating || scroll.contentOffset.y < -scroll.adjustedContentInset.top - 1 else { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            self?.browser.tabs.first { $0.webView === webView }?.reload()
        }
    }

    /// The page fills the screen and scrolls under the clock and the bar.
    /// WebKit is told what they cover, and the page scrolls that much
    /// further at each end, so its top rests below the clock and its end
    /// scrolls clear of the bar.
    private func inset(_ webView: WKWebView) {
        guard isViewLoaded, let safe = view.window?.safeAreaInsets else { return }
        let covered = UIEdgeInsets(top: safe.top, left: 0, bottom: safe.bottom + Look.barHeight, right: 0)
        if webView.obscuredContentInsets != covered { webView.obscuredContentInsets = covered }
        let scroll = webView.scrollView
        if scroll.contentInset != covered {
            scroll.contentInset = covered
            scroll.verticalScrollIndicatorInsets.bottom = Look.barHeight
        }
    }

    // MARK: Pictures

    private var isStill: Bool {
        isHome() && !tabSwipe.move.isMoving && !edgeSwipe.isMoving && cover == nil && !scrolling.isScrolling && !(shown?.view.isHolding ?? true)
    }

    /// A page that is loading, or has just finished, has changed.
    private func loadingChanged() {
        guard let tab = browser.selected else { return }
        _ = (tab.isLoading, tab.progress, tab.backForward)
        taking.changed()
    }

    /// A page's alert, confirm or prompt was answered, which can change it.
    func answered() {
        taking.changed()
    }

    /// The page as it shows now, kept for the grid, the stack and swipes.
    private func takePicture() {
        guard let tab = shown, tab === browser.selected, tab.backForward.index >= 0, !page.bounds.isEmpty else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: page.bounds, format: format).image { _ in
            page.drawHierarchy(in: page.bounds, afterScreenUpdates: false)
        }
        pictures.keep(image, of: tab, among: browser.tabs)
    }
}
