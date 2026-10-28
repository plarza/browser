import AppKit
import WebKit

/// Find on page, with WebKit's own find engine (Safari's): every match
/// highlighted, the current one marked, and a count. Nothing is put into
/// the page.
extension Tab {
    private static let options: UInt = (1 << 0) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 9) // case-insensitive, wrap, indicator, highlight, match index
    private static let backwards: UInt = 1 << 3

    /// The next (or previous) match; the result arrives in `onFind`.
    public func find(_ text: String, backwards: Bool = false) {
        guard !text.isEmpty else { hideFind(); onFind?(0, nil); return }
        finder.tab = self
        webView.perform(NSSelectorFromString("_setFindDelegate:"), with: finder)
        let selector = NSSelectorFromString("_findString:options:maxCount:")
        typealias Call = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
        unsafeBitCast(webView.method(for: selector), to: Call.self)(webView, selector, text as NSString, Tab.options | (backwards ? Tab.backwards : 0), 1000)
    }

    public func hideFind() {
        webView.perform(NSSelectorFromString("_hideFindUI"))
    }
}

/// WebKit's answers: how many matches, and which one is current.
@MainActor
final class FindReporter: NSObject {
    weak var tab: Tab?

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func didFind(_ webView: WKWebView, matches: UInt, string: String, index: Int) {
        tab?.onFind?(Int(matches), index >= 0 ? index : nil)
    }

    @objc(_webView:didFailToFindString:)
    func didFail(_ webView: WKWebView, string: String) {
        tab?.onFind?(0, nil)
    }
}
