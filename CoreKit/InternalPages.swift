import AppKit
import WebKit

/// about://history and about://settings. Served on a scheme of Core's own
/// (`core:`) that only these pages' web views have a handler for: a website
/// can't reach it, and the pages can reach nothing else of Core's.
@MainActor
public final class InternalPage: NSObject, WKURLSchemeHandler {
    static let shared = InternalPage()
    static let scheme = "core"
    static let pages = ["history", "settings"]

    /// The page an about: address names, if it is one of Core's.
    nonisolated public static func page(_ url: URL?) -> String? {
        guard let url, url.scheme == "about" else { return nil }
        let name = url.host ?? url.absoluteString.replacingOccurrences(of: "about:", with: "")
        return pages.contains(name) ? name : nil
    }

    nonisolated public static func address(_ page: String) -> URL { URL(string: "about://\(page)")! }
    static func start(_ page: String) -> URL { URL(string: "core://\(page)/")! }

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
        func lines(_ name: String) -> [String] {
            value(name).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let ok = Data("true".utf8)

        switch (url.host ?? "", url.path) {
        case ("history", "/search"):
            json(task, url, History.shared.search(value("q")))
        case ("history", "/remove"):
            History.shared.remove(value("u"))
            respond(task, url, "application/json", ok)
        case ("history", "/clear"):
            History.shared.clear()
            respond(task, url, "application/json", ok)

        case ("settings", "/state"):
            json(task, url, state())
        case ("settings", "/search"):
            Preferences.shared.settings.searchTemplate = value("v").trimmingCharacters(in: .whitespaces)
            respond(task, url, "application/json", ok)
        case ("settings", "/whitelist"):
            Preferences.shared.settings.whitelist = lines("v")
            json(task, url, state())
        case ("settings", "/lists"):
            Preferences.shared.settings.filterLists = lines("v")
            Blocker.shared.refresh(force: true)
            json(task, url, state())
        case ("settings", "/lists-default"):
            Preferences.shared.settings.filterLists = Settings.defaultFilterLists
            json(task, url, state())
        case ("settings", "/install"):
            Task {
                await Extensions.shared.install(from: value("v"))
                json(task, url, state())
            }
        case ("settings", "/folder"):
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                Task {
                    if response == .OK, let folder = panel.url { await Extensions.shared.installFolder(folder) }
                    self.json(task, url, self.state())
                }
            }
            if let window = webView.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
        case ("settings", "/uninstall"):
            Task {
                await Extensions.shared.remove(value("v"))
                json(task, url, state())
            }

        case (let host, _) where Self.pages.contains(host):
            respond(task, url, "text/html", Data(InternalPage.document(host).utf8))
        default:
            task.didFailWithError(URLError(.fileDoesNotExist))
        }
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private struct State: Encodable {
        let searchTemplate: String
        let whitelist: [String]
        let filterLists: [String]
        let rules: Int
        let trouble: String?
        let extensions: [Extensions.Installed]
    }

    private func state() -> State {
        let settings = Preferences.shared.settings
        return State(
            searchTemplate: settings.searchTemplate, whitelist: settings.whitelist, filterLists: settings.filterLists,
            rules: Blocker.shared.ruleCount, trouble: Blocker.shared.trouble ?? Extensions.shared.trouble,
            extensions: Extensions.shared.installed
        )
    }

    private func json(_ task: any WKURLSchemeTask, _ url: URL, _ value: some Encodable) {
        respond(task, url, "application/json", (try? JSONEncoder().encode(value)) ?? Data("null".utf8))
    }

    private func respond(_ task: any WKURLSchemeTask, _ url: URL, _ type: String, _ data: Data) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "\(type); charset=utf-8",
            "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src core:",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    // MARK: Pages

    /// Native controls wherever there are some: WebKit draws a plain
    /// `<button>`, `<input>` or `<textarea>` as macOS's own.
    static let style = """
    :root { color-scheme: light dark; --dim: #86868b; --hover: #00000008; --mark: #ffd60a66; }
    @media (prefers-color-scheme: dark) { :root { --dim: #98989d; --hover: #ffffff0d; --mark: #ffd60a44; } }
    body { margin: 0; background: Canvas; color: CanvasText; font: 13px/1.4 -apple-system, system-ui; }
    main { max-width: 680px; margin: 0 auto; padding: 32px 24px 64px; }
    a { color: inherit; text-decoration: none; }
    """

    static func document(_ page: String) -> String {
        let (title, body) = page == "settings" ? ("Settings", settings) : ("History", history)
        return "<!doctype html><html lang=en><head><meta charset=utf-8><title>\(title)</title><style>\(style)</style></head><body>\(body)</body></html>"
    }

    static let history = """
    <style>
    .bar { display: flex; gap: 8px; position: sticky; top: 0; background: Canvas; padding: 8px 0 12px; }
    .bar input { flex: 1; font-size: 14px; }
    ol { list-style: none; margin: 0; padding: 0; }
    li { display: flex; align-items: center; border-radius: 8px; animation: in .2s ease-out both; }
    li:hover, li.active { background: var(--hover); }
    @keyframes in { from { opacity: 0; transform: translateY(3px); } }
    li a { flex: 1; min-width: 0; padding: 7px 10px; }
    .t, .u { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .t { font-weight: 500; }
    .u { color: var(--dim); font-size: 12px; }
    mark { background: var(--mark); color: inherit; border-radius: 2px; }
    li button { visibility: hidden; margin-right: 6px; }
    li:hover button { visibility: visible; }
    .none { color: var(--dim); text-align: center; padding: 48px 0; }
    </style>
    <main>
    <div class=bar><input id=q type=search placeholder="Search History" autofocus autocomplete=off spellcheck=false><button id=clear>Clear History</button></div>
    <ol id=list></ol>
    </main>
    <script>
    const q = document.getElementById('q'), list = document.getElementById('list');
    let results = [], active = -1, timer;
    const esc = s => s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
    const mark = (text, words) => words.reduce((html, w) => html.replace(new RegExp('(' + esc(w).replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&') + ')', 'gi'), '<mark>$1</mark>'), esc(text));
    async function search() {
      results = await (await fetch('core://history/search?q=' + encodeURIComponent(q.value.trim()))).json();
      active = -1;
      const words = q.value.trim().toLowerCase().split(/\\s+/).filter(Boolean);
      if (!results.length) { list.innerHTML = '<div class=none>' + (words.length ? 'No Results' : 'No History') + '</div>'; return; }
      list.innerHTML = results.map((v, i) => {
        const bare = v.url.replace(/^https?:\\/\\//, '').replace(/^www\\./, '');
        return '<li data-i=' + i + ' style="animation-delay:' + Math.min(i, 20) * 10 + 'ms"><a href="' + esc(v.url) + '"><div class=t>' + mark(v.title || bare, words) + '</div><div class=u>' + mark(bare, words) + '</div></a><button>Remove</button></li>';
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
      if (e.target.tagName !== 'BUTTON') return;
      await fetch('core://history/remove?u=' + encodeURIComponent(results[+e.target.closest('li').dataset.i].url));
      search();
    });
    document.getElementById('clear').addEventListener('click', async () => { await fetch('core://history/clear'); search(); });
    search();
    </script>
    """

    static let settings = """
    <style>
    section { margin-bottom: 28px; }
    h2 { font-size: 13px; font-weight: 600; margin: 0 0 8px; }
    input[type=text], textarea { width: 100%; box-sizing: border-box; font: 12px ui-monospace, monospace; }
    textarea { min-height: 96px; resize: vertical; }
    .row { display: flex; gap: 8px; align-items: center; margin-top: 8px; }
    .row input { flex: 1; }
    .picks button { font-size: 12px; }
    .dim { color: var(--dim); font-size: 12px; }
    .spacer { flex: 1; }
    ul { list-style: none; padding: 0; margin: 8px 0 0; }
    li { display: flex; align-items: center; padding: 4px 0; }
    li span { flex: 1; }
    .trouble { color: #ff3b30; font-size: 12px; margin-top: 6px; }
    </style>
    <main>
    <section>
      <h2>Search Engine</h2>
      <input type=text id=search placeholder="https://example.com/search?q=%s" spellcheck=false>
      <div class="row picks" id=picks></div>
    </section>
    <section>
      <h2>Keep Cookies For</h2>
      <textarea id=whitelist placeholder="example.com" spellcheck=false></textarea>
    </section>
    <section>
      <h2>Filter Lists</h2>
      <textarea id=lists spellcheck=false></textarea>
      <div class=row><button id=fetch>Save and Update</button><button id=defaults>Defaults</button><span class=spacer></span><span class=dim id=rules></span></div>
    </section>
    <section>
      <h2>Extensions</h2>
      <div class=row><input type=text id=link placeholder="Chrome Web Store link or ID" spellcheck=false><button id=install>Install</button><button id=folder>Folder…</button></div>
      <ul id=extensions></ul>
    </section>
    <div class=trouble id=trouble></div>
    </main>
    <script>
    const $ = id => document.getElementById(id);
    const call = async (path, v) => (await fetch('core://settings/' + path + (v === undefined ? '' : '?v=' + encodeURIComponent(v)))).json();
    const engines = [['Mullvad Leta', 'https://leta.mullvad.net/search?q=%s'], ['DuckDuckGo', 'https://duckduckgo.com/?q=%s'], ['Brave', 'https://search.brave.com/search?q=%s'], ['Startpage', 'https://www.startpage.com/do/search?query=%s'], ['Kagi', 'https://kagi.com/search?q=%s']];
    function show(s) {
      if (document.activeElement !== $('search')) $('search').value = s.searchTemplate;
      if (document.activeElement !== $('whitelist')) $('whitelist').value = s.whitelist.join('\\n');
      if (document.activeElement !== $('lists')) $('lists').value = s.filterLists.join('\\n');
      $('rules').textContent = s.rules ? s.rules.toLocaleString() + ' rules' : '';
      $('trouble').textContent = s.trouble || '';
      $('extensions').innerHTML = s.extensions.map(e => '<li><span></span><button data-id="' + e.id + '">Remove</button></li>').join('');
      [...$('extensions').querySelectorAll('span')].forEach((span, i) => span.textContent = s.extensions[i].name);
    }
    $('picks').innerHTML = engines.map(([name]) => '<button>' + name + '</button>').join('');
    [...$('picks').children].forEach((b, i) => b.onclick = () => { $('search').value = engines[i][1]; call('search', engines[i][1]); });
    $('search').onchange = () => call('search', $('search').value);
    $('whitelist').onchange = async () => show(await call('whitelist', $('whitelist').value));
    $('fetch').onclick = async () => show(await call('lists', $('lists').value));
    $('defaults').onclick = async () => { $('lists').blur(); show(await call('lists-default')); };
    $('install').onclick = async () => { $('install').disabled = true; show(await call('install', $('link').value)); $('install').disabled = false; $('link').value = ''; };
    $('link').onkeydown = e => { if (e.key === 'Enter') $('install').click(); };
    $('folder').onclick = async () => show(await call('folder'));
    $('extensions').onclick = async e => { if (e.target.dataset.id) show(await call('uninstall', e.target.dataset.id)); };
    call('state').then(show);
    setInterval(async () => show(await call('state')), 3000);
    </script>
    """
}
