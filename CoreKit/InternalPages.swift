import AppKit
import WebKit

/// about://history and about://settings. Served on a scheme of Core's own
/// (`core:`) that only these pages' web views have a handler for: a website
/// can't reach it, and the pages can reach nothing else of Core's.
@MainActor
public final class InternalPage: NSObject, WKURLSchemeHandler {
    static let shared = InternalPage()
    static let scheme = "core"
    static let pages = ["history", "settings", "help"]

    /// Every shortcut, as [section, action, keys]: the shell fills this in
    /// from its own menus, so the help page can't drift from them.
    public static var shortcuts: () -> [[String]] = { [] }

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

        case ("help", "/shortcuts"):
            json(task, url, Self.shortcuts())
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
        case ("settings", "/tabs"):
            Preferences.shared.settings.newTabPosition = Settings.TabPosition(rawValue: value("v")) ?? .below
            json(task, url, state())
        case ("settings", "/newtab"):
            Preferences.shared.settings.newTabPage = Settings.NewTabPage(rawValue: value("v")) ?? .image
            json(task, url, state())
        case ("settings", "/newtab-color"):
            Preferences.shared.settings.newTabColor = value("v")
            json(task, url, state())
        case ("settings", "/newtab-image"):
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                if response == .OK, let picked = panel.url {
                    try? FileManager.default.removeItem(at: Settings.newTabImage)
                    try? FileManager.default.copyItem(at: picked, to: Settings.newTabImage)
                    Preferences.shared.settings.newTabPage = .image
                    Preferences.shared.newTabImageChanged()
                }
                self.json(task, url, self.state())
            }
            if let window = webView.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
        case ("settings", "/newtab-default"):
            try? FileManager.default.removeItem(at: Settings.newTabImage)
            Preferences.shared.newTabImageChanged()
            json(task, url, state())
        case ("settings", "/newtab-preview"):
            let data = Settings.newTabImageInUse.flatMap { try? Data(contentsOf: $0) } ?? Data()
            respond(task, url, "image/webp", data)
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
        let newTabPosition: String
        let newTabPage: String
        let newTabColor: String
        let customImage: Bool
        let rules: Int
        let trouble: String?
        let extensions: [Extensions.Installed]
    }

    private func state() -> State {
        let settings = Preferences.shared.settings
        return State(
            searchTemplate: settings.searchTemplate, whitelist: settings.whitelist, filterLists: settings.filterLists,
            newTabPosition: settings.newTabPosition.rawValue,
            newTabPage: settings.newTabPage.rawValue, newTabColor: settings.newTabColor,
            customImage: FileManager.default.fileExists(atPath: Settings.newTabImage.path),
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
            "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: core:; connect-src core:",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    // MARK: Pages

    /// One look for every control on Core's pages, the address field's: a
    /// 28-point white capsule with a hairline edge, and the system focus ring.
    static let style = """
    :root { color-scheme: light dark; --dim: #86868b; --edge: #0000001a; --hover: #0000000a; --mark: #ffd60a66; --ring: #0a84ff59; --on: #1d1d1f; --on-text: #ffffff; }
    @media (prefers-color-scheme: dark) { :root { --dim: #98989d; --edge: #ffffff26; --hover: #ffffff12; --mark: #ffd60a44; --on: #f5f5f7; --on-text: #1d1d1f; } }
    body { margin: 0; background: Canvas; color: CanvasText; font: 13px/1.4 -apple-system, system-ui; -webkit-font-smoothing: antialiased; }
    main { max-width: 680px; margin: 0 auto; padding: 32px 24px 64px; }
    a { color: inherit; text-decoration: none; }
    [hidden] { display: none !important; }
    input, button, textarea { -webkit-appearance: none; appearance: none; box-sizing: border-box; font: 13px -apple-system, system-ui; color: inherit; background: Canvas; border: 1px solid var(--edge); outline: none; transition: background .15s, box-shadow .15s, border-color .15s; }
    input, button { height: 28px; border-radius: 14px; padding: 0 14px; }
    textarea { border-radius: 10px; padding: 8px 12px; }
    button { cursor: default; white-space: nowrap; }
    button:hover { background: var(--hover); }
    button:active { background: var(--edge); }
    input:focus, textarea:focus { border-color: transparent; box-shadow: 0 0 0 3px var(--ring); }
    input[type=search] { padding-left: 30px; background: Canvas url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='14' height='14' fill='none' stroke='%2386868b' stroke-width='1.6' stroke-linecap='round'%3E%3Ccircle cx='6' cy='6' r='4.6'/%3E%3Cpath d='M9.4 9.4l3.4 3.4'/%3E%3C/svg%3E") no-repeat 11px center; }
    input::placeholder, textarea::placeholder { color: var(--dim); }
    """

    static func document(_ page: String) -> String {
        let (title, body) = page == "settings" ? ("Settings", settings) : page == "help" ? ("Help", help) : ("History", history)
        return "<!doctype html><html lang=en><head><meta charset=utf-8><title>\(title)</title><style>\(style)</style></head><body>\(body)</body></html>"
    }

    static let history = """
    <style>
    .bar { display: flex; gap: 8px; position: sticky; top: 0; background: Canvas; padding: 8px 0 12px; }
    .bar input { flex: 1; }
    ol { list-style: none; margin: 0; padding: 0; }
    li { display: flex; align-items: center; border-radius: 8px; animation: in .2s ease-out both; }
    li:hover, li.active { background: var(--hover); }
    @keyframes in { from { opacity: 0; transform: translateY(3px); } }
    li a { flex: 1; min-width: 0; padding: 7px 10px; }
    .t, .u { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .t { font-weight: 500; }
    .u { color: var(--dim); font-size: 12px; }
    mark { background: var(--mark); color: inherit; border-radius: 2px; }
    li button { visibility: hidden; margin-right: 6px; height: 24px; padding: 0 10px; font-size: 12px; }
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
    document.getElementById('clear').addEventListener('click', async () => {
      if (!confirm('Clear all history?')) return;
      await fetch('core://history/clear');
      search();
    });
    search();
    </script>
    """

    static let help = """
    <style>
    h2 { font-size: 13px; font-weight: 600; margin: 24px 0 6px; }
    h2:first-child { margin-top: 0; }
    .k { display: flex; justify-content: space-between; align-items: center; padding: 6px 0; border-bottom: 1px solid var(--edge); }
    kbd { font: 12px -apple-system, system-ui; border: 1px solid var(--edge); border-radius: 6px; padding: 2px 7px; margin-left: 4px; }
    </style>
    <main id=list></main>
    <script>
    const esc = s => s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
    fetch('core://help/shortcuts').then(r => r.json()).then(rows => {
      const groups = {};
      for (const [section, action, keys] of rows) (groups[section] ||= []).push([action, keys]);
      document.getElementById('list').innerHTML = Object.entries(groups).map(([section, items]) =>
        '<h2>' + esc(section) + '</h2>' + items.map(([action, keys]) =>
          '<div class=k><span>' + esc(action) + '</span><span>' + keys.split(' or ').map(k => '<kbd>' + esc(k) + '</kbd>').join(' ') + '</span></div>').join('')).join('');
    });
    </script>
    """

    static let settings = """
    <style>
    section { margin-bottom: 28px; }
    h2 { font-size: 13px; font-weight: 600; margin: 0 0 8px; }
    input[type=text], textarea { width: 100%; }
    textarea { height: 200px; resize: none; font: 12px/1.5 ui-monospace, monospace; }
    .picks button { display: inline-flex; align-items: center; gap: 6px; }
    .picks img { width: 16px; height: 16px; border-radius: 4px; }
    .row { display: flex; gap: 8px; align-items: center; margin-top: 8px; }
    .row input { flex: 1; }
    .dim { color: var(--dim); font-size: 12px; }
    .segments { display: inline-flex; padding: 2px; gap: 2px; border: 1px solid var(--edge); border-radius: 14px; height: 28px; box-sizing: border-box; }
    .segments button { border: 0; height: 22px; border-radius: 11px; padding: 0 12px; transition: none; }
    .segments button.on, .segments button.on:hover { background: var(--on); color: var(--on-text); }
    #preview { width: 112px; height: 63px; object-fit: cover; border-radius: 8px; border: 1px solid var(--edge); }
    .swatch { width: 28px; height: 28px; border-radius: 14px; overflow: hidden; border: 1px solid var(--edge); position: relative; }
    .swatch input { position: absolute; inset: -8px; width: 44px; height: 44px; padding: 0; border: 0; cursor: default; }
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
      <h2>New Tabs Open</h2>
      <div class=segments id=tabs><button data-v=below>Below Current Tab</button><button data-v=top>At the Top</button><button data-v=bottom>At the Bottom</button></div>
    </section>
    <section>
      <h2>New Tab Page</h2>
      <div class=segments id=newtab><button data-v=image>Image</button><button data-v=color>Color</button><button data-v=blank>Blank</button></div>
      <div class=row id=imagerow><img id=preview alt=""><button id=pick>Choose Image…</button><button id=reset>Use Default</button></div>
      <div class=row id=colorrow><label class=swatch><input type=color id=color></label><span class=dim id=hex></span></div>
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
    // Icons are built in: opening Settings asks nothing of these sites.
    const engines = [
      ['Google', 'https://www.google.com/search?q=%s', 'data:image/png;base64,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'],
      ['DuckDuckGo', 'https://duckduckgo.com/?q=%s', 'data:image/png;base64,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'],
      ['Brave', 'https://search.brave.com/search?q=%s', 'data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iNTYiIGhlaWdodD0iNjQiIHZpZXdCb3g9IjAgMCA1NiA2NCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48cGF0aCBmaWxsLXJ1bGU9ImV2ZW5vZGQiIGNsaXAtcnVsZT0iZXZlbm9kZCIgZD0iTTUzLjI5MiAxNS4zMjFsMS41LTMuNjc2cy0xLjkwOS0yLjA0My00LjIyNy00LjM1OGMtMi4zMTctMi4zMTUtNy4yMjUtLjk1My03LjIyNS0uOTUzTDM3Ljc1MSAwSDE4LjEybC01LjU4OSA2LjMzNHMtNC45MDgtMS4zNjItNy4yMjUuOTUzQzIuOTg4IDkuNjAyIDEuMDggMTEuNjQ1IDEuMDggMTEuNjQ1bDEuNSAzLjY3Ni0xLjkxIDUuNDQ3czUuNjE0IDIxLjIzNiA2LjI3MiAyMy44M2MxLjI5NSA1LjEwNiAyLjE4MSA3LjA4IDUuODYyIDkuNjY4IDMuNjggMi41ODcgMTAuMzYgNy4wOCAxMS40NSA3Ljc2MiAxLjA5MS42OCAyLjQ1NSAxLjg0IDMuNjgyIDEuODQgMS4yMjcgMCAyLjU5LTEuMTYgMy42OC0xLjg0IDEuMDkxLS42ODEgNy43Ny01LjE3NSAxMS40NTItNy43NjIgMy42OC0yLjU4NyA0LjU2Ny00LjU2MiA1Ljg2Mi05LjY2OC42NTctMi41OTQgNi4yNy0yMy44MyA2LjI3LTIzLjgzbC0xLjkwOC01LjQ0N3oiIGZpbGw9InVybCgjcGFpbnQwX2xpbmVhcikiLz48cGF0aCBmaWxsLXJ1bGU9ImV2ZW5vZGQiIGNsaXAtcnVsZT0iZXZlbm9kZCIgZD0iTTM0Ljg4OCAxMS41MDhjLjgxOCAwIDYuODg1LTEuMTU3IDYuODg1LTEuMTU3czcuMTg5IDguNjggNy4xODkgMTAuNTM2YzAgMS41MzQtLjYxOSAyLjEzNC0xLjM0NyAyLjg0Mi0uMTUyLjE0OC0uMzEuMy0uNDY3LjQ2OGwtNS4zOSA1LjcxN2E5LjQyIDkuNDIgMCAwMS0uMTc2LjE4Yy0uNTM4LjU0LTEuMzMgMS4zMzYtLjc3MiAyLjY1OGwuMTE1LjI2OWMuNjEzIDEuNDMyIDEuMzcgMy4yLjQwNyA0Ljk5LTEuMDI1IDEuOTA2LTIuNzggMy4xNzgtMy45MDUgMi45NjctMS4xMjQtLjIxLTMuNzY2LTEuNTg5LTQuNzM3LTIuMjE4LS45NzEtLjYzLTQuMDUtMy4xNjYtNC4wNS00LjEzNyAwLS44MDkgMi4yMTQtMi4xNTUgMy4yOS0yLjgxLjIxNC0uMTMuMzgzLS4yMzIuNDgtLjI5OC4xMTEtLjA3NS4yOTctLjE5LjUyNi0uMzMyLjk4MS0uNjEgMi43NTQtMS43MSAyLjc5OS0yLjE5Ny4wNTUtLjYwMi4wMzQtLjc3OC0uNzU4LTIuMjY0LS4xNjgtLjMxNi0uMzY1LS42NTQtLjU2OC0xLjAwNC0uNzU0LTEuMjk1LTEuNTk4LTIuNzQ1LTEuNDEtMy43ODQuMjEtMS4xNzMgMi4wNS0xLjg0NSAzLjYwOC0yLjQxNS4xOTQtLjA3LjM4NS0uMTQuNTY3LS4yMDlsMS42MjMtLjYwOWMxLjU1Ni0uNTgyIDMuMjg0LTEuMjI5IDMuNTctMS4zNi4zOTQtLjE4MS4yOTItLjM1NS0uOTAzLS40NjhhNTQuNjU1IDU0LjY1NSAwIDAxLS41OC0uMDZjLTEuNDgtLjE1Ny00LjIwOS0uNDQ2LTUuNTM1LS4wNzctLjI2MS4wNzMtLjU1My4xNTItLjg2LjIzNS0xLjQ5LjQwMy0zLjMxNy44OTctMy40OTMgMS4xODItLjAzLjA1LS4wNi4wOTMtLjA4OS4xMzMtLjE2OC4yMzgtLjI3Ny4zOTQtLjA5MSAxLjQwNi4wNTUuMzAyLjE2OS44OTUuMzEgMS42MjkuNDEgMi4xNDggMS4wNTMgNS40OTggMS4xMzQgNi4yNS4wMTEuMTA2LjAyNC4yMDcuMDM2LjMwNS4xMDMuODQuMTcxIDEuMzk5LS44MDUgMS42MjJsLS4yNTUuMDU4Yy0xLjEwMi4yNTItMi43MTcuNjIzLTMuMy42MjMtLjU4NCAwLTIuMi0uMzctMy4zMDItLjYyM2wtLjI1NC0uMDU4Yy0uOTc2LS4yMjMtLjkwNy0uNzgyLS44MDQtMS42MjIuMDEyLS4wOTguMDI0LS4yLjAzNS0uMzA1LjA4MS0uNzUzLjcyNS00LjExMiAxLjEzNy02LjI1OS4xNC0uNzMuMjUzLTEuMzIuMzA4LTEuNjIuMTg1LTEuMDEyLjA3Ni0xLjE2OC0uMDkyLTEuNDA2YTMuNzQzIDMuNzQzIDAgMDEtLjA5LS4xMzNjLS4xNzQtLjI4NS0yLS43NzktMy40OTEtMS4xODItLjMwNy0uMDgzLS42LS4xNjItLjg2LS4yMzUtMS4zMjctLjM3LTQuMDU1LS4wOC01LjUzNS4wNzctLjIyNi4wMjQtLjQyMi4wNDUtLjU4LjA2LTEuMTk2LjExMy0xLjI5Ny4yODctLjkwMy40NjguMjg1LjEzMSAyLjAxMy43NzggMy41NjggMS4zNi41OTcuMjIzIDEuMTcuNDM3IDEuNjI0LjYwOS4xODMuMDY5LjM3My4xMzguNTY4LjIxIDEuNTU4LjU3IDMuMzk4IDEuMjQxIDMuNjA4IDIuNDE0LjE4NyAxLjAzOS0uNjU3IDIuNDg5LTEuNDEgMy43ODQtLjIwNC4zNS0uNC42ODgtLjU2OSAxLjAwNC0uNzkxIDEuNDg2LS44MTIgMS42NjItLjc1NyAyLjI2NC4wNDQuNDg4IDEuODE2IDEuNTg3IDIuNzk4IDIuMTk3LjIyOS4xNDIuNDE1LjI1Ny41MjYuMzMyLjA5OC4wNjYuMjY2LjE2OC40OC4yOTggMS4wNzYuNjU0IDMuMjkgMiAzLjI5IDIuODEgMCAuOTctMy4wNzggMy41MDctNC4wNSA0LjEzNy0uOTcuNjMtMy42MTIgMi4wMDgtNC43MzcgMi4yMTgtMS4xMjQuMjEtMi44OC0xLjA2MS0zLjkwNC0yLjk2Ni0uOTYzLTEuNzkxLS4yMDctMy41NTkuNDA2LTQuOTlsLjExNS0uMjdjLjU1OS0xLjMyMi0uMjMzLTIuMTE4LS43NzItMi42NThhOS4zNzcgOS4zNzcgMCAwMS0uMTc1LS4xOGwtNS4zOS01LjcxN2MtLjE1OC0uMTY3LS4zMTYtLjMyLS40NjgtLjQ2OC0uNzI4LS43MDctMS4zNDYtMS4zMDgtMS4zNDYtMi44NDIgMC0xLjg1NSA3LjE4OS0xMC41MzYgNy4xODktMTAuNTM2czYuMDY2IDEuMTU3IDYuODg0IDEuMTU3Yy42NTMgMCAxLjkxMy0uNDMzIDMuMjI3LS44ODUuMzMzLS4xMTQuNjY5LS4yMyAxLS4zNCAxLjYzNS0uNTQ1IDIuNzI2LS41NDkgMi43MjYtLjU0OXMxLjA5LjAwNCAyLjcyNi41NDljLjMzLjExLjY2Ny4yMjYgMSAuMzQgMS4zMTMuNDUyIDIuNTc0Ljg4NSAzLjIyNi44ODV6bS0xLjA0MSAzMC43MDZjMS4yODIuNjYgMi4xOTIgMS4xMjggMi41MzYgMS4zNDMuNDQ1LjI3OC4xNzQuODAzLS4yMzIgMS4wOS0uNDA1LjI4NS01Ljg1MyA0LjQ5OS02LjM4MSA0Ljk2NWwtLjIxNS4xOTFjLS41MDkuNDU5LTEuMTU5IDEuMDQ0LTEuNjIgMS4wNDQtLjQ2IDAtMS4xMS0uNTg2LTEuNjItMS4wNDRsLS4yMTMtLjE5MWMtLjUzLS40NjYtNS45NzctNC42OC02LjM4Mi00Ljk2Ni0uNDA1LS4yODYtLjY3Ny0uODEtLjIzMi0xLjA5LjM0NC0uMjE0IDEuMjU1LS42ODMgMi41MzktMS4zNDRsMS4yMi0uNjI5YzEuOTItLjk5MiA0LjMxNS0xLjgzNyA0LjY4OS0xLjgzNy4zNzMgMCAyLjc2Ny44NDQgNC42ODkgMS44MzcuNDM2LjIyNi44NDUuNDM3IDEuMjIyLjYzeiIgZmlsbD0iI2ZmZiIvPjxwYXRoIGZpbGwtcnVsZT0iZXZlbm9kZCIgY2xpcC1ydWxlPSJldmVub2RkIiBkPSJNNDMuMzQgNi4zMzRMMzcuNzUxIDBIMTguMTJsLTUuNTg5IDYuMzM0cy00LjkwOC0xLjM2Mi03LjIyNS45NTNjMCAwIDYuNTQ0LS41OSA4Ljc5MyAzLjA2NCAwIDAgNi4wNjYgMS4xNTcgNi44ODQgMS4xNTcuODE4IDAgMi41OS0uNjggNC4yMjYtMS4yMjUgMS42MzYtLjU0NSAyLjcyNy0uNTQ5IDIuNzI3LS41NDlzMS4wOS4wMDQgMi43MjYuNTQ5IDMuNDA4IDEuMjI1IDQuMjI2IDEuMjI1Yy44MTggMCA2Ljg4NS0xLjE1NyA2Ljg4NS0xLjE1NyAyLjI0OS0zLjY1NCA4Ljc5Mi0zLjA2NCA4Ljc5Mi0zLjA2NC0yLjMxNy0yLjMxNS03LjIyNS0uOTUzLTcuMjI1LS45NTN6IiBmaWxsPSJ1cmwoI3BhaW50MV9saW5lYXIpIi8+PGRlZnM+PGxpbmVhckdyYWRpZW50IGlkPSJwYWludDBfbGluZWFyIiB4MT0iLjY3MSIgeTE9IjY0LjMxOSIgeDI9IjU1LjIiIHkyPSI2NC4zMTkiIGdyYWRpZW50VW5pdHM9InVzZXJTcGFjZU9uVXNlIj48c3RvcCBzdG9wLWNvbG9yPSIjRjUwIi8+PHN0b3Agb2Zmc2V0PSIuNDEiIHN0b3AtY29sb3I9IiNGNTAiLz48c3RvcCBvZmZzZXQ9Ii41ODIiIHN0b3AtY29sb3I9IiNGRjIwMDAiLz48c3RvcCBvZmZzZXQ9IjEiIHN0b3AtY29sb3I9IiNGRjIwMDAiLz48L2xpbmVhckdyYWRpZW50PjxsaW5lYXJHcmFkaWVudCBpZD0icGFpbnQxX2xpbmVhciIgeDE9IjYuMjc4IiB5MT0iMTEuNDY2IiB4Mj0iNTAuNTY1IiB5Mj0iMTEuNDY2IiBncmFkaWVudFVuaXRzPSJ1c2VyU3BhY2VPblVzZSI+PHN0b3Agc3RvcC1jb2xvcj0iI0ZGNDUyQSIvPjxzdG9wIG9mZnNldD0iMSIgc3RvcC1jb2xvcj0iI0ZGMjAwMCIvPjwvbGluZWFyR3JhZGllbnQ+PC9kZWZzPjwvc3ZnPg=='],
      ['Startpage', 'https://www.startpage.com/do/search?query=%s', 'data:image/png;base64,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'],
      ['Kagi', 'https://kagi.com/search?q=%s', 'data:image/png;base64,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']
    ];
    function show(s) {
      if (document.activeElement !== $('search')) $('search').value = s.searchTemplate;
      kept = s.whitelist;
      if (document.activeElement !== $('whitelist')) $('whitelist').value = s.whitelist.join('\\n');
      if (document.activeElement !== $('lists')) $('lists').value = s.filterLists.join('\\n');
      [...$('newtab').children].forEach(b => b.classList.toggle('on', b.dataset.v === s.newTabPage));
      $('imagerow').hidden = s.newTabPage !== 'image';
      $('colorrow').hidden = s.newTabPage !== 'color';
      $('reset').hidden = !s.customImage;
      if (document.activeElement !== $('color')) $('color').value = s.newTabColor;
      $('hex').textContent = s.newTabColor.toUpperCase();
      [...$('tabs').children].forEach(b => b.classList.toggle('on', b.dataset.v === s.newTabPosition));
      $('rules').textContent = s.rules ? s.rules.toLocaleString() + ' rules' : '';
      $('trouble').textContent = s.trouble || '';
      $('extensions').innerHTML = s.extensions.map(e => '<li><span></span><button data-id="' + e.id + '">Remove</button></li>').join('');
      [...$('extensions').querySelectorAll('span')].forEach((span, i) => span.textContent = s.extensions[i].name);
    }
    $('picks').innerHTML = engines.map(([name, , icon]) => '<button><img src="' + icon + '" alt="">' + name + '</button>').join('');
    [...$('picks').children].forEach((b, i) => b.onclick = () => { $('search').value = engines[i][1]; call('search', engines[i][1]); });
    $('newtab').onclick = async e => { if (e.target.dataset.v) show(await call('newtab', e.target.dataset.v)); };
    const refreshPreview = () => $('preview').src = 'core://settings/newtab-preview?' + Date.now();
    $('pick').onclick = async () => { show(await call('newtab-image')); refreshPreview(); };
    $('reset').onclick = async () => {
      if (!confirm('Go back to the default image?')) return;
      show(await call('newtab-default'));
      refreshPreview();
    };
    $('color').oninput = async () => { $('hex').textContent = $('color').value.toUpperCase(); await call('newtab-color', $('color').value); };
    refreshPreview();
    $('tabs').onclick = async e => { if (e.target.dataset.v) show(await call('tabs', e.target.dataset.v)); };
    $('search').onchange = () => call('search', $('search').value);
    let kept = [];
    $('whitelist').onchange = async () => {
      // Taking a domain off deletes its cookies and storage for good.
      const now = $('whitelist').value.split('\\n').map(d => d.trim().toLowerCase()).filter(Boolean);
      const gone = kept.filter(d => !now.includes(d));
      if (gone.length && !confirm('Delete the cookies and data kept for ' + gone.join(', ') + '?')) { $('whitelist').value = kept.join('\\n'); return; }
      show(await call('whitelist', $('whitelist').value));
    };
    $('fetch').onclick = async () => show(await call('lists', $('lists').value));
    $('defaults').onclick = async () => {
      if (!confirm('Replace your filter lists with the defaults?')) return;
      $('lists').blur();
      show(await call('lists-default'));
    };
    $('install').onclick = async () => { $('install').disabled = true; show(await call('install', $('link').value)); $('install').disabled = false; $('link').value = ''; };
    $('link').onkeydown = e => { if (e.key === 'Enter') $('install').click(); };
    $('folder').onclick = async () => show(await call('folder'));
    $('extensions').onclick = async e => {
      if (!e.target.dataset.id) return;
      const name = e.target.previousElementSibling.textContent;
      if (!confirm('Remove ' + name + '? Its data, such as a password vault, is deleted with it.')) return;
      show(await call('uninstall', e.target.dataset.id));
    };
    call('state').then(show);
    setInterval(async () => show(await call('state')), 3000);
    </script>
    """
}
