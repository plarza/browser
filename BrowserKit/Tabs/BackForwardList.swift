import Foundation

/// A tab's back and forward list. Browser keeps its own: WebKit's belongs
/// to one web view, and a wipe throws the web view away.
public struct BackForwardList: Equatable, Sendable {
    public private(set) var entries: [URL] = []
    /// Where the tab is in `entries`; -1 before it has been anywhere.
    public private(set) var index = -1

    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index < entries.count - 1 }
    var isEmpty: Bool { entries.isEmpty }
    var current: URL? { index >= 0 ? entries[index] : nil }
    var back: URL? { canGoBack ? entries[index - 1] : nil }
    var forward: URL? { canGoForward ? entries[index + 1] : nil }

    /// How a load changes the list.
    enum Move: Sendable {
        /// Somewhere new: whatever was forward is gone.
        case new
        case back, forward
        /// The same place again.
        case reload
        /// A page sending itself somewhere without a click (a script
        /// redirect) takes the place of its entry instead of adding one, so
        /// Back doesn't land on a page that sends you straight forward again.
        case replace
    }

    /// The new tab page, as an entry: a tab that began blank goes back to it.
    static let blank = URL(string: "about:newtab")!

    /// Leaving a blank tab: it stays behind as the first entry.
    mutating func beginBlank() {
        entries = [BackForwardList.blank]
        index = 0
    }

    mutating func record(_ url: URL, as move: Move) {
        switch move {
        case .new:
            guard current != url else { break }
            entries.removeSubrange((index + 1)...)
            entries.append(url)
            index = entries.count - 1
        case .back:
            index = max(0, index - 1)
            entries[index] = url
        case .forward:
            index = min(entries.count - 1, index + 1)
            entries[index] = url
        case .reload, .replace:
            if index >= 0 { entries[index] = url }
        }
    }

    /// What a page did to its address without loading: WebKit's
    /// `_WKSameDocumentNavigationType`.
    enum InPage: Int {
        case anchor, push, replace, pop
    }

    /// The page changed its own address (pushState, as GitHub and most apps
    /// do, or an anchor). True if that added an entry.
    mutating func changedInPage(to url: URL, by change: InPage) -> Bool {
        guard index >= 0, entries[index] != url else { return false }
        switch change {
        case .replace:
            entries[index] = url
        case .pop:
            // The page's own history.back() or forward() within the document.
            if back == url { index -= 1 } else if forward == url { index += 1 } else { entries[index] = url }
        case .anchor, .push:
            record(url, as: .new)
            return true
        }
        return false
    }
}
