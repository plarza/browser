import AppKit
import BrowserKit

/// The sidebar: the extensions' buttons beside the traffic lights, the
/// address field, the tabs, and this session's downloads at its foot. Pure
/// white and flush with the page; its edge drags, and ⌘S hides it.
@MainActor
final class Sidebar: Surface {
    static let widths: ClosedRange<CGFloat> = 200 ... 420

    let actionBar: ActionBar
    let addressField: AddressField
    let tabList: TabList
    let downloadRows = DownloadRows()
    /// The edge between the sidebar and the page: drag to resize.
    let edge = SidebarEdge()

    /// The sidebar is wider, narrower, hidden or back; true when it is
    /// animating there, so what lies under it can keep step.
    var onResize: (_ animated: Bool) -> Void = { _ in }
    private(set) var isShown = true
    private(set) var width: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: "sidebarWidth"))
        return saved > 0 ? min(max(saved, widths.lowerBound), widths.upperBound) : 248
    }()

    private var widthConstraint: NSLayoutConstraint?
    private var leading: NSLayoutConstraint?

    init(browser: Browser) {
        actionBar = ActionBar(browser: browser)
        addressField = AddressField(browser: browser)
        tabList = TabList(browser: browser)
        super.init(frame: .zero)
        // The suggestions last: over the tabs, under the field.
        let suggestions = addressField.suggestions
        for view in [addressField, actionBar, tabList, downloadRows, suggestions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Below the traffic lights.
            addressField.topAnchor.constraint(equalTo: topAnchor, constant: 42),
            addressField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            addressField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            suggestions.topAnchor.constraint(equalTo: addressField.bottomAnchor, constant: 6),
            suggestions.leadingAnchor.constraint(equalTo: addressField.leadingAnchor, constant: -2),
            suggestions.trailingAnchor.constraint(equalTo: addressField.trailingAnchor, constant: 2),

            // In the traffic lights' row, after them; the window gives it
            // their centre line.
            actionBar.heightAnchor.constraint(equalToConstant: 22),
            actionBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 78),
            actionBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            tabList.topAnchor.constraint(equalTo: addressField.bottomAnchor, constant: 10),
            tabList.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tabList.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tabList.bottomAnchor.constraint(equalTo: downloadRows.topAnchor, constant: -6),

            downloadRows.leadingAnchor.constraint(equalTo: tabList.leadingAnchor),
            downloadRows.trailingAnchor.constraint(equalTo: tabList.trailingAnchor),
            downloadRows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        edge.onDrag = { [weak self] delta in self?.resize(by: delta) }
        edge.onEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(width), forKey: "sidebarWidth")
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Down the left of `root`, top to bottom, with its edge over whatever
    /// comes after it.
    func place(in root: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        edge.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(self)
        root.addSubview(edge)
        let leading = leadingAnchor.constraint(equalTo: root.leadingAnchor)
        let width = widthAnchor.constraint(equalToConstant: width)
        self.leading = leading
        widthConstraint = width
        NSLayoutConstraint.activate([
            leading,
            topAnchor.constraint(equalTo: root.topAnchor),
            bottomAnchor.constraint(equalTo: root.bottomAnchor),
            width,

            edge.centerXAnchor.constraint(equalTo: trailingAnchor),
            edge.topAnchor.constraint(equalTo: root.topAnchor),
            edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 8),
        ])
    }

    private func resize(by delta: CGFloat) {
        width = min(max(width + delta, Sidebar.widths.lowerBound), Sidebar.widths.upperBound)
        widthConstraint?.constant = width
        onResize(false)
    }

    /// ⌘S. Hidden, the page has the whole window, traffic lights and all.
    func toggle() {
        isShown.toggle()
        let show = isShown
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.animator().alphaValue = show ? 1 : 0
        }
        edge.isHidden = !show
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = Motion.ease
            context.allowsImplicitAnimation = true
            leading?.constant = show ? 0 : -width
            animator().alphaValue = show ? 1 : 0
            onResize(true)
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }
}

/// The sidebar's edge: drag to resize.
@MainActor
final class SidebarEdge: NSView {
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}

    override func resetCursorRects() { addCursorRect(bounds, cursor: .columnResize) }

    override func mouseDown(with event: NSEvent) {
        var last = event.locationInWindow.x
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            MainActor.assumeIsolated {
                guard let event, event.type == .leftMouseDragged else {
                    stop.pointee = true
                    if event != nil { self.onEnd() }
                    return
                }
                let x = event.locationInWindow.x
                self.onDrag(x - last)
                last = x
            }
        }
    }
}
