import WebKit

// The Chrome Web Store, made to work for Core. The store sees a browser that
// isn't Chrome: it shows a "Switch to Chrome" banner and a grey "Add to
// Chrome" button. On the store's own pages only, the banner goes and the
// button becomes "Add to Core". The script runs in WebKit's isolated world,
// where the store's own scripts can't see it, and what gets installed is
// read from the tab's address by Core, never from anything the page says.

@MainActor
final class StoreRelay: NSObject, WKScriptMessageHandler {
    static let shared = StoreRelay()
    static let name = "coreStore"

    /// Into every tab's content controller; it returns at once anywhere but
    /// the store.
    static func install(in controller: WKUserContentController) {
        controller.addUserScript(userScript)
        controller.add(shared, contentWorld: .defaultClient, name: name)
    }

    static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let web = message.webView, let address = web.url, address.host == "chromewebstore.google.com",
              let body = message.body as? [String: Any], let id = Crx.id(in: address.absoluteString)
        else { return }
        if body["add"] != nil {
            tell(web, busy: id)
            Task {
                await Extensions.shared.install(from: id)
                tell(web, busy: nil)
            }
        } else {
            tell(web, busy: nil)
        }
    }

    /// What is installed and what is on its way, so the button can say
    /// "Added to Core" or "Adding…".
    private func tell(_ web: WKWebView, busy: String?) {
        let installed = Extensions.shared.installed.map(\.id)
        guard let data = try? JSONSerialization.data(withJSONObject: ["installed": installed, "busy": busy.map { $0 as Any } ?? NSNull()]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.__coreStore && window.__coreStore.state(\(json))", in: nil, in: .defaultClient)
    }

    static let script = """
    (() => {
      if (location.hostname !== 'chromewebstore.google.com' || window.__coreStore) return;
      let installed = [], busy = null;
      const here = () => (location.pathname.match(/\\/detail\\/(?:[^\\/]+\\/)?([a-p]{32})/) || [])[1];
      const post = message => window.webkit.messageHandlers.coreStore.postMessage(message);

      // Keeps the store's look: only the button's last piece of text changes.
      function words(button, text) {
        const walk = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
        let last = null;
        for (let n = walk.nextNode(); n; n = walk.nextNode()) if (n.nodeValue.trim()) last = n;
        if (last) last.nodeValue = text; else button.textContent = text;
      }

      function label(button) {
        const id = here();
        const done = !!id && installed.includes(id), going = !!id && busy === id;
        words(button, done ? 'Added to Core' : going ? 'Adding…' : 'Add to Core');
        button.disabled = done || going;
      }

      // The block around a "get Chrome" link, as far up as it stays small
      // and holds no install button.
      function promptAround(link) {
        let block = null;
        for (let up = link.parentElement; up && up !== document.body; up = up.parentElement) {
          if (up.querySelector('button[data-core], button[disabled]') || (up.innerText || '').length > 200) break;
          block = up;
        }
        return block;
      }

      function sweep() {
        if (here()) {
          for (const theirs of document.querySelectorAll('button[disabled]:not([data-core])')) {
            if (!/chrome/i.test(theirs.textContent || '')) continue;
            const ours = theirs.cloneNode(true);
            for (const name of ['disabled', 'jsaction', 'jscontroller', 'jsname', 'jslog']) ours.removeAttribute(name);
            ours.dataset.core = 'add';
            theirs.dataset.core = 'store';
            theirs.style.display = 'none';
            theirs.after(ours);
          }
        }
        for (const link of document.querySelectorAll('a[href*="google.com/chrome"]:not([data-core])')) {
          link.dataset.core = 'seen';
          const block = promptAround(link);
          if (block) block.style.display = 'none';
        }
        for (const card of document.querySelectorAll('[role="dialog"]:not([data-core])')) {
          if (card.querySelector('img[src*="chrome"]')) { card.dataset.core = 'prompt'; card.style.display = 'none'; }
        }
        document.querySelectorAll('button[data-core="add"]').forEach(label);
      }

      // Before the store's own listeners, which sit on the document.
      addEventListener('click', event => {
        const ours = event.target.closest && event.target.closest('button[data-core="add"]');
        if (!ours) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        if (!ours.disabled) post({ add: true });
      }, true);

      window.__coreStore = { state(next) { installed = next.installed || []; busy = next.busy; sweep(); } };

      // The store redraws itself as you move around it.
      let queued = null;
      new MutationObserver(() => { clearTimeout(queued); queued = setTimeout(sweep, 80); })
        .observe(document.documentElement, { childList: true, subtree: true });
      sweep();
      post({ hello: true });
    })();
    """
}
