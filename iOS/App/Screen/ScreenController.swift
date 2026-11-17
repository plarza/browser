import BrowserKit
import SwiftUI
import UIKit

/// The iPhone's screen: the selected tab's page with the bar over it, the
/// grid behind, and the address sheet over both. It arranges them and
/// moves between them; the tabs and what they show are BrowserKit's.
///
/// The live page sits at the back and is never scaled. Whenever it would
/// have to be (shrinking into its card, stepping back behind the address
/// sheet) it leaves the screen and its picture stands in for it.
final class ScreenController: UIViewController, ScreenActions {
    let browser: Browser
    let messages = Messages()
    private(set) lazy var alerts = Alerts(presenter: self)
    private let pictures = Pictures()
    private let bar = Bar()

    private(set) lazy var pages = PagesController(browser: browser, bar: bar, pictures: pictures) { [unowned self] in isHome }
    /// What's behind the address sheet, and steps back for it: everything
    /// on screen but the live page.
    private let behind = Behind()
    private lazy var grid = GridController(browser: browser, pictures: pictures, screen: self)
    private let shrunk = ShrunkPage()
    private let frost = Frost()
    private let barHolder = UIView()
    private lazy var sheet = AddressSheetController(behind: behind) { [unowned self] in go($0, for: $1) } landed: { [unowned self] in settled() }
    private var opening: GridOpening!

    /// The live page is on screen: nothing stands in for it.
    private var isHome = true
    /// Which way the address bar is being dragged, settled by the first move.
    private var drag: Drag?
    private var following: [Observer] = []

    private enum Drag { case sideways, up }

    init(browser: Browser) {
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layers

    override func viewDidLoad() {
        super.viewDidLoad()
        let backdrop = Backdrop()
        behind.layer.cornerCurve = .continuous
        behind.clipsToBounds = true
        for layer in [backdrop, pages.view!, behind, grid.view!, shrunk, sheet.view!] {
            layer.frame = view.bounds
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        view.addSubview(backdrop)
        add(pages, to: view)
        view.addSubview(behind)
        add(grid, to: behind)
        behind.addSubview(shrunk)
        behind.addSubview(frost)
        behind.addSubview(barHolder)
        add(UIHostingController(rootView: BarView(browser: browser, bar: bar, pictures: pictures, screen: self)), to: barHolder)
        add(sheet, to: view)

        let message = UIHostingController(rootView: MessageCapsule(messages: messages))
        message.view.isUserInteractionEnabled = false
        message.view.frame = view.bounds
        message.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        add(message, to: view)

        opening = GridOpening(in: view, shrunk: shrunk, grid: grid.view, gridBar: grid.bar, bar: barHolder, frost: frost)
        // With no tab there is no page: the grid, empty.
        if browser.selected == nil {
            isHome = false
            pages.view.alpha = 0
        }
        opening.move.set(browser.selected == nil ? 1 : 0)
        following = [Observer { [weak self] in self?.selectionChanged() }]
    }

    private func add(_ child: UIViewController, to holder: UIView) {
        addChild(child)
        if child.view.superview == nil {
            child.view.backgroundColor = .clear
            child.view.frame = holder.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        holder.addSubview(child.view)
        child.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        frost.layout(width: view.bounds.width, top: view.safeAreaInsets.top)
        let height = Look.barHeight + view.safeAreaInsets.bottom
        barHolder.bounds = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        barHolder.center = CGPoint(x: view.bounds.midX, y: view.bounds.maxY - height / 2)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        pictures.shed(keeping: browser.tabs)
    }

    // MARK: Home and away

    /// The selected tab, or what it shows, changed.
    private func selectionChanged() {
        let closed = browser.selected == nil ? pages.lastPicture() : nil
        pages.update()
        frost.isWanted = browser.selected.map { $0.page == nil && !$0.isBlank } ?? false
        guard let closed, opening.move.value < 1 else { return }
        // The last tab closed itself. With no card to land on, the page
        // shrinks towards the middle and fades, leaving the empty grid.
        if isHome {
            isHome = false
            pages.view.alpha = 0
            shrunk.card = nil
            shrunk.standIn(with: closed)
            shrunk.place(opening.move.shown)
        }
        opening.move.spring(to: 1) { [unowned self] in settled() }
    }

    /// The live page leaves the screen and its picture, exactly as the
    /// page shows now, stands in for it, bound for its card.
    private func leavePage() {
        guard isHome else { return }
        // The copy first: it is exact only while the page is still home.
        let copy = pages.standIn()
        isHome = false
        let tab = browser.selected
        if let tab { grid.scroll(to: tab) }
        shrunk.card = tab.flatMap { grid.picture(of: $0, in: behind) }
        shrunk.standIn(with: copy)
        shrunk.place(opening.move.shown)
        grid.away = tab?.id
        pages.view.alpha = 0
    }

    /// `tab`'s picture leaves its card, bound for the page. One already in
    /// flight carries on as it is.
    private func leaveCard(of tab: Tab) {
        guard grid.away != tab.id || !shrunk.isStandingIn else { return }
        shrunk.card = grid.picture(of: tab, in: behind)
        shrunk.standIn(with: .of(tab, in: pictures))
        shrunk.place(opening.move.shown)
        grid.away = tab.id
    }

    /// A move came to rest. On its card, the card shows its own picture;
    /// back on the page with the sheet away, the live page shows again.
    private func settled() {
        guard !opening.move.isMoving, !sheet.move.isMoving else { return }
        if opening.move.value >= 1 {
            grid.away = nil
            shrunk.standDown()
        } else if sheet.move.value <= 0, browser.selected != nil {
            isHome = true
            pages.view.alpha = 1
            grid.away = nil
            shrunk.standDown()
        }
    }

    // MARK: What the bar, the grid and the sheet ask for

    func openGrid() {
        leavePage()
        bar.isCollapsed = false
        opening.move.spring(to: 1) { [unowned self] in settled() }
    }

    func show(_ tab: Tab) {
        browser.select(tab)
        pages.update()
        guard !isHome else { return }
        leaveCard(of: tab)
        opening.move.spring(to: 0) { [unowned self] in settled() }
    }

    func edit(_ target: AddressSheetTarget) {
        let tab = target == .current ? browser.selected : nil
        leavePage()
        sheet.raise(for: tab == nil ? .newTab : .current, address: tab?.url?.absoluteString ?? "")
    }

    func showSettings() {
        present(UIHostingController(rootView: SettingsSheet(screen: self)), animated: true)
    }

    func show(_ page: InternalPage) {
        closeSettings()
        browser.show(page)
        showPage()
    }

    /// A link from another app: a new tab, in front.
    func open(_ url: URL) {
        closeSettings()
        browser.open(url)
        showPage()
    }

    /// Settings goes; a question waiting for its answer stays.
    private func closeSettings() {
        if let presented = presentedViewController, !(presented is UIAlertController) { dismiss(animated: true) }
    }

    /// The selected tab's page, whatever was showing.
    private func showPage() {
        if sheet.isUp { sheet.lower() }
        if let tab = browser.selected { show(tab) }
    }

    /// What was typed or picked in the address sheet. True if it went
    /// somewhere, so the sheet can go.
    private func go(_ text: String, for target: AddressSheetTarget) -> Bool {
        let showing = browser.selected
        switch browser.go(text, inNewTab: target == .newTab) {
        case .go:
            guard let tab = browser.selected else { return true }
            if opening.isOpen {
                show(tab)
            } else {
                pages.update()
                // Another tab's page now: the card behind the sheet becomes it.
                if tab !== showing {
                    UIView.transition(with: shrunk, duration: 0.2, options: .transitionCrossDissolve) { [self] in
                        shrunk.standIn(with: .of(tab, in: pictures))
                    }
                }
            }
            return true
        case .needsSearchEngine:
            messages.say("No search engine set. Add one in Settings.")
            return false
        case nil:
            return false
        }
    }

    func addressBarPanned(_ pan: UIPanGestureRecognizer) {
        let moved = pan.translation(in: view), speed = pan.velocity(in: view)
        switch pan.state {
        case .began:
            // Counted from here, so nothing jumps by the distance the
            // finger went before the drag was known for one.
            pan.setTranslation(.zero, in: view)
            if abs(speed.x) >= abs(speed.y) {
                guard isHome else { return drag = nil }
                drag = .sideways
                pages.tabSwipe.began()
            } else if speed.y < 0 {
                drag = .up
                leavePage()
                opening.began()
            } else {
                drag = nil
            }
        case .changed:
            switch drag {
            case .sideways: pages.tabSwipe.changed(by: moved.x)
            case .up: opening.changed(by: -moved.y)
            case nil: break
            }
        case .ended, .cancelled, .failed:
            switch drag {
            case .sideways: pages.tabSwipe.ended(velocity: speed.x)
            case .up: opening.ended(speed: -speed.y) { [unowned self] in settled() }
            case nil: break
            }
            drag = nil
        default:
            break
        }
    }
}

/// What's behind the address sheet. It holds things that sit over the
/// page; a touch on none of them is the page's.
private final class Behind: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
