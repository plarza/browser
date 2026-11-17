import AppKit
import BrowserKit

/// Pictures of pages by tab and place in its back and forward list, for
/// swipes: the latest few, taken by WebKit off the main thread, kept in
/// memory only. A closed tab's pictures go with it.
@MainActor
final class PagePictures {
    private let browser: Browser
    private var pictures: [String: NSImage] = [:]
    /// The pictures' keys, oldest first.
    private var order: [String] = []
    private var settle: Task<Void, Never>?
    private var following: [Observer] = []
    /// The selected tab, and whether it was loading when last looked at.
    private var watched: (tab: UUID, loading: Bool)?
    private static let limit = 8

    init(browser: Browser) {
        self.browser = browser
        following = [
            Observer { [weak self] in self?.keep(Set(browser.tabs.map(\.id))) },
            // The page finished loading: its picture, for swiping back to it.
            Observer { [weak self] in
                guard let self, let tab = browser.selected else { return }
                let loading = tab.isLoading
                if let watched, watched.tab == tab.id, watched.loading, !loading { captureSoon() }
                watched = (tab.id, loading)
            },
        ]
    }

    private static func key(_ tab: UUID, _ index: Int) -> String { "\(tab) \(index)" }

    /// The picture of the page `tab` has at `index` in its list, if one was taken.
    func picture(of tab: Tab, at index: Int) -> NSImage? {
        pictures[PagePictures.key(tab.id, index)]
    }

    /// Only the pictures of tabs still open.
    private func keep(_ tabs: Set<UUID>) {
        let closed = order.filter { key in !tabs.contains { key.hasPrefix("\($0) ") } }
        for key in closed { pictures[key] = nil }
        order.removeAll(where: closed.contains)
    }

    /// The selected tab's page, once it has been still a moment.
    func captureSoon() {
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled, let self, let tab = browser.selected { capture(tab) }
        }
    }

    /// The page `tab` shows now, for its place in the list.
    func capture(_ tab: Tab) {
        let index = tab.backForward.index
        guard index >= 0, tab.url != nil, tab.page == nil, tab.view.window != nil else { return }
        let key = PagePictures.key(tab.id, index), webView = tab.webView
        Task { [weak self] in
            guard let image = try? await webView.takeSnapshot(configuration: nil), let self else { return }
            pictures[key] = image
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > PagePictures.limit { pictures[order.removeFirst()] = nil }
        }
    }
}
