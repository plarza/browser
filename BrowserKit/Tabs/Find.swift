import WebKit

/// Find on page, with WebKit's own find engine (Safari's): every match
/// highlighted, the current one marked, and a count. Nothing is put into
/// the page.
extension Tab {
    /// WebKit's answer to a search.
    public struct Found: Equatable, Sendable {
        public var matches: Int
        /// Which match is the current one, counting from 0.
        public var current: Int?
    }

    /// `_WKFindOptions`: case-insensitive, wrap around, show the indicator,
    /// show the highlight, report the match index.
    private static let options: UInt = (1 << 0) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 9)
    private static let backwards: UInt = 1 << 3

    /// The next (or previous) match; the answer arrives in `found`.
    public func find(_ text: String, backwards: Bool = false) {
        guard !text.isEmpty else {
            hideFind()
            found = Found(matches: 0)
            return
        }
        finder.tab = self
        webView.perform(NSSelectorFromString("_setFindDelegate:"), with: finder)
        let find = NSSelectorFromString("_findString:options:maxCount:")
        typealias Find = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
        let options = Tab.options | (backwards ? Tab.backwards : 0)
        unsafeBitCast(webView.method(for: find), to: Find.self)(webView, find, text as NSString, options, 1000)
    }

    public func hideFind() {
        webView.perform(NSSelectorFromString("_hideFindUI"))
        found = nil
    }
}

/// WebKit's find delegate (`_WKFindDelegate`).
@MainActor
final class FindReporter: NSObject {
    weak var tab: Tab?

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func didFind(_ webView: WKWebView, matches: UInt, string: String, index: Int) {
        tab?.found = Tab.Found(matches: Int(matches), current: index >= 0 ? index : nil)
    }

    @objc(_webView:didFailToFindString:)
    func didFail(_ webView: WKWebView, string: String) {
        tab?.found = Tab.Found(matches: 0)
    }
}
