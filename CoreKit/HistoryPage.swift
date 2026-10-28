import Foundation
import WebKit

/// about://history. Served on a scheme of Core's own (`core:`) that only
/// this page's web view has a handler for: a website can't reach it, and
/// the page can reach nothing else of Core's.
@MainActor
public final class HistoryPage: NSObject, WKURLSchemeHandler {
    static let shared = HistoryPage()
    nonisolated public static let address = URL(string: "about://history")!
    static let scheme = "core"
    static let start = URL(string: "core://history/")!

    nonisolated public static func isHistory(_ url: URL?) -> Bool {
        guard let url, url.scheme == "about" else { return false }
        return url.host == "history" || url.absoluteString == "about:history"
    }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
        switch url.path {
        case "/search":
            let visits = History.shared.search(value("q"))
            let data = (try? JSONEncoder().encode(visits)) ?? Data("[]".utf8)
            respond(task, url, "application/json", data)
        case "/remove":
            History.shared.remove(value("u"))
            respond(task, url, "application/json", Data("true".utf8))
        case "/clear":
            History.shared.clear()
            respond(task, url, "application/json", Data("true".utf8))
        default:
            respond(task, url, "text/html", Data(HistoryPage.html.utf8))
        }
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, _ url: URL, _ type: String, _ data: Data) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "\(type); charset=utf-8",
            "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src core:",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    static let html = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>History</title>
    <style>
    :root { color-scheme: light dark; --bg: #fff; --fg: #1d1d1f; --dim: #86868b; --line: #0000000d; --hover: #00000008; --mark: #ffd60a66; --accent: #0071e3; }
    @media (prefers-color-scheme: dark) { :root { --bg: #000; --fg: #f5f5f7; --dim: #98989d; --line: #ffffff14; --hover: #ffffff0d; --mark: #ffd60a44; --accent: #2997ff; } }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/1.4 -apple-system, system-ui; -webkit-font-smoothing: antialiased; }
    main { max-width: 760px; margin: 0 auto; padding: 56px 24px 80px; }
    header { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 20px; }
    h1 { font-size: 28px; font-weight: 700; letter-spacing: -0.02em; margin: 0; }
    button.clear { background: none; border: 0; color: var(--dim); font: inherit; cursor: pointer; padding: 4px 8px; border-radius: 6px; transition: color .15s, background .15s; }
    button.clear:hover { color: #ff3b30; background: var(--hover); }
    .search { position: sticky; top: 0; background: var(--bg); padding: 8px 0 14px; z-index: 1; }
    input { width: 100%; font: inherit; font-size: 16px; color: inherit; background: var(--hover); border: 1.5px solid transparent; border-radius: 12px; padding: 11px 14px; outline: none; transition: border-color .2s, background .2s; }
    input:focus { border-color: color-mix(in srgb, var(--accent) 55%, transparent); background: transparent; }
    .count { color: var(--dim); font-size: 12px; margin: 0 4px 6px; height: 16px; }
    ol { list-style: none; margin: 0; padding: 0; }
    li { display: flex; align-items: center; gap: 10px; border-radius: 10px; transition: background .15s, opacity .2s, transform .2s; animation: in .22s cubic-bezier(.2,.9,.25,1) both; }
    li:hover, li.active { background: var(--hover); }
    li.gone { opacity: 0; transform: translateX(8px); }
    @keyframes in { from { opacity: 0; transform: translateY(4px); } }
    a { flex: 1; min-width: 0; display: block; padding: 9px 12px; color: inherit; text-decoration: none; }
    .title, .url { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .title { font-weight: 500; }
    .url { color: var(--dim); font-size: 12px; }
    mark { background: var(--mark); color: inherit; border-radius: 3px; }
    .remove { opacity: 0; background: none; border: 0; color: var(--dim); font-size: 16px; width: 28px; height: 28px; margin-right: 6px; border-radius: 7px; cursor: pointer; transition: opacity .15s, background .15s; }
    li:hover .remove { opacity: 1; }
    .remove:hover { background: var(--line); color: var(--fg); }
    .empty { color: var(--dim); text-align: center; padding: 60px 0; }
    </style></head>
    <body><main>
    <header><h1>History</h1><button class="clear" id="clear">Clear History…</button></header>
    <div class="search"><input id="q" type="search" placeholder="Search history" autofocus autocomplete="off" spellcheck="false"></div>
    <div class="count" id="count"></div>
    <ol id="list"></ol>
    </main>
    <script>
    const q = document.getElementById('q'), list = document.getElementById('list'), count = document.getElementById('count');
    let results = [], active = -1, timer;
    const esc = s => s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
    function highlight(text, words) {
      let html = esc(text);
      for (const w of words) {
        if (!w) continue;
        const re = new RegExp('(' + esc(w).replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&') + ')', 'gi');
        html = html.replace(re, '<mark>$1</mark>');
      }
      return html;
    }
    async function search() {
      const text = q.value.trim();
      const r = await fetch('core://history/search?q=' + encodeURIComponent(text));
      results = await r.json();
      active = -1;
      render(text.toLowerCase().split(/\\s+/).filter(Boolean));
    }
    function render(words) {
      count.textContent = q.value.trim() ? results.length + (results.length === 1 ? ' match' : ' matches') : '';
      if (!results.length) { list.innerHTML = '<div class="empty">' + (q.value.trim() ? 'Nothing matches.' : 'No history yet.') + '</div>'; return; }
      list.innerHTML = results.map((v, i) => {
        const bare = v.url.replace(/^https?:\\/\\//, '').replace(/^www\\./, '');
        const title = v.title || bare;
        return '<li data-i="' + i + '" style="animation-delay:' + Math.min(i, 20) * 12 + 'ms"><a href="' + esc(v.url) + '"><div class="title">' + highlight(title, words) + '</div><div class="url">' + highlight(bare, words) + '</div></a><button class="remove" title="Remove from History">×</button></li>';
      }).join('');
    }
    q.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(search, 60); });
    q.addEventListener('keydown', e => {
      const rows = list.querySelectorAll('li');
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        active = Math.max(0, Math.min(rows.length - 1, active + (e.key === 'ArrowDown' ? 1 : -1)));
        rows.forEach((r, i) => r.classList.toggle('active', i === active));
        rows[active]?.scrollIntoView({ block: 'nearest' });
      } else if (e.key === 'Enter' && results.length) {
        location.href = results[Math.max(active, 0)].url;
      }
    });
    list.addEventListener('click', async e => {
      const button = e.target.closest('.remove');
      if (!button) return;
      e.preventDefault();
      const li = button.closest('li'), v = results[+li.dataset.i];
      li.classList.add('gone');
      await fetch('core://history/remove?u=' + encodeURIComponent(v.url));
      setTimeout(search, 180);
    });
    document.getElementById('clear').addEventListener('click', async () => {
      if (!confirm('Clear all history? This can’t be undone.')) return;
      await fetch('core://history/clear');
      search();
    });
    search();
    </script></body></html>
    """
}
