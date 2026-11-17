import WebKit

/// Middle-clicking a link opens it in a fresh tab. WebKit on macOS doesn't
/// navigate for an auxiliary click, so one is listened for in the isolated
/// world, in every frame, and the link sent to the tab it was clicked in.
@MainActor
final class AuxiliaryClicks: NSObject, WKScriptMessageHandler {
    private static let shared = AuxiliaryClicks()
    private static let name = "browserOpenLink"

    private static let script = WKUserScript(source: """
    addEventListener('auxclick', event => {
      if (!event.isTrusted || event.button !== 1) return;
      const link = event.composedPath().find(node => node.matches?.('a[href], area[href]'));
      if (!link || !/^(https?:|about:)/i.test(link.href)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      window.webkit.messageHandlers.\(name).postMessage(link.href);
    }, true);
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)

    static func install(in controller: WKUserContentController) {
        controller.add(shared, contentWorld: .defaultClient, name: name)
        controller.addUserScript(script)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab = Tab.showing(message.webView), let text = message.body as? String,
              let url = URL(string: text), ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        tab.browser?.open(url, from: tab)
    }
}
