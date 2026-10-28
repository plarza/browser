import WebKit

/// WebKit on macOS doesn't navigate for an auxiliary click. Listen in the
/// isolated world, in every frame, and send the link to its owning tab.
@MainActor
final class Links: NSObject, WKScriptMessageHandler {
    static let shared = Links()
    private static let name = "azoteOpenLink"

    static func install(in controller: WKUserContentController) {
        controller.add(shared, contentWorld: .defaultClient, name: name)
        controller.addUserScript(userScript)
    }

    static var userScript: WKUserScript {
        WKUserScript(source: """
        addEventListener('auxclick', event => {
          if (!event.isTrusted || event.button !== 1) return;
          const link = event.composedPath().find(node => node.matches?.('a[href], area[href]'));
          if (!link || !/^(https?:|about:)/i.test(link.href)) return;
          event.preventDefault();
          event.stopImmediatePropagation();
          window.webkit.messageHandlers.azoteOpenLink.postMessage(link.href);
        }, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let tab = webView.navigationDelegate as? Tab,
              tab.webView === webView, let text = message.body as? String,
              let url = URL(string: text), ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        tab.delegate?.tab(tab, openInNewTab: url)
    }
}
