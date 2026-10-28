import WebKit

// Copyright (c) 2026 Office Commun. MIT License (see LICENSES/MIT-Office-Commun.txt).
//
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
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        controller.add(shared, contentWorld: .defaultClient, name: name)
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
    (function () {
      if (location.hostname !== 'chromewebstore.google.com' || window.__coreStore) return;
      var state = { installed: [], busy: null };

      function pageID() {
        var m = location.pathname.match(/\\/detail\\/(?:[^\\/]+\\/)?([a-p]{32})/);
        return m ? m[1] : null;
      }

      function theirs() {
        var buttons = document.querySelectorAll('button[disabled]');
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i];
          if (!b.dataset.core && /chrome/i.test(b.textContent || '')) return b;
        }
        return null;
      }

      // From the banner's own button up, as far as it goes without taking in
      // the header beside it: short, and holding no install button.
      function bannerOf(button) {
        var box = null, up = button.parentElement;
        while (up && up !== document.body) {
          if (up.querySelector('button[disabled], button[data-core]')) break;
          if ((up.innerText || '').length > 160) break;
          box = up;
          up = up.parentElement;
        }
        return box;
      }

      function hideBanner() {
        // And the floating "Switch to Chrome?" card, known by the Chrome logo
        // it carries in any language — it sits right over the button.
        var cards = document.querySelectorAll('[role="dialog"]');
        for (var c = 0; c < cards.length; c++) {
          if (!cards[c].dataset.core && cards[c].querySelector('img[src*="productlogos/chrome"]')) {
            cards[c].style.display = 'none';
            cards[c].dataset.core = 'promo';
          }
        }
        var buttons = document.querySelectorAll('button:not([disabled])');
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i];
          if (b.dataset.core || !/chrome/i.test(b.getAttribute('aria-label') || '')) continue;
          var box = bannerOf(b);
          if (box && !box.dataset.core) {
            box.style.display = 'none';
            box.dataset.core = 'banner';
          }
        }
      }

      // The words only, so the button keeps the store's own shape and colour.
      function label(button, text) {
        var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
        var node, last = null;
        while ((node = walker.nextNode())) { if (node.nodeValue.trim()) last = node; }
        if (last) last.nodeValue = text; else button.textContent = text;
      }

      function render(ours) {
        var id = pageID();
        var installed = !!id && state.installed.indexOf(id) >= 0;
        var busy = !!id && state.busy === id;
        label(ours, installed ? 'Added to Core' : (busy ? 'Adding…' : 'Add to Core'));
        ours.disabled = installed || busy;
      }

      function mend() {
        hideBanner();
        if (!pageID()) return;
        var original = theirs();
        if (original && original.parentNode) {
          var ours = original.cloneNode(true);
          ['disabled', 'jsaction', 'jscontroller', 'jsname', 'jslog', 'aria-describedby'].forEach(function (name) {
            ours.removeAttribute(name);
          });
          ours.dataset.core = 'add';
          original.dataset.core = 'theirs';
          original.style.display = 'none';
          original.parentNode.insertBefore(ours, original.nextSibling);
          window.webkit.messageHandlers.coreStore.postMessage({ placed: pageID() });
        }
        renderAll();
      }

      // The store keeps the pages it has left, hidden, beside the one it shows.
      function renderAll() {
        var mine = document.querySelectorAll('button[data-core="add"]');
        for (var i = 0; i < mine.length; i++) render(mine[i]);
      }

      // Caught on the window, before the store's own handlers — which listen
      // on the document — can see the click at all.
      window.addEventListener('click', function (e) {
        var mine = e.target && e.target.closest && e.target.closest('button[data-core="add"]');
        if (!mine) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        if (!mine.disabled) window.webkit.messageHandlers.coreStore.postMessage({ add: true });
      }, true);

      window.__coreStore = {
        state: function (next) {
          state = next || state;
          renderAll();
        }
      };

      // The store is one page that rewrites itself: whatever it redraws, mend
      // again. A timer rather than a frame — a tab out of sight gets no frames.
      var queued = false;
      new MutationObserver(function () {
        if (queued) return;
        queued = true;
        setTimeout(function () { queued = false; mend(); }, 60);
      }).observe(document.documentElement, { childList: true, subtree: true });
      mend();
    })();
    """
}
