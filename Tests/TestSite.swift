#if DEBUG
import AppKit

/// What the self-test's server serves: plain pages by name, and the few
/// that do something (redirect, frame another site, download, a userscript
/// with what it requires, the filter list).
enum TestSite {
    struct Response {
        var status = "200 OK"
        var type: String
        var body: Data
        var headers: [(String, String)] = []
        /// The length the head claims when the body sent is only its start.
        var promised: Int?

        init(_ type: String, _ body: Data) {
            self.type = type
            self.body = body
        }

        init(_ type: String, _ text: String) {
            self.init(type, Data(text.utf8))
        }
    }

    /// Enough rules to need two content rule lists (WebKit takes 150,000 each).
    static let ruleCount = 160_000

    static func respond(to request: URLComponents) -> Response {
        let path = request.path
        switch path {
        case _ where path.hasPrefix("/page/"):
            let name = path.dropFirst(6).replacingOccurrences(of: "-", with: " ")
            return page(name, "<h1>\(name)</h1><p>" + String(repeating: "WebKit is a browser engine. ", count: 12) + "</p>")
        case "/redirect":
            // Sends itself on by script, once loaded, with no click.
            return page("Redirect", "<script>addEventListener('load', () => setTimeout(() => location.replace('/page/after'), 50))</script>")
        case "/moved":
            var moved = Response("text/plain", "")
            moved.status = "301 Moved Permanently"
            moved.headers = [("Location", "/page/one")]
            return moved
        case "/search":
            return page("Results", "<p>Results for \(request.queryItems?.first?.value ?? "")</p>")
        case "/scriptlets":
            // Parses JSON a list prunes on this host, and frames a page from
            // the other host, which a list's rule for that host reaches.
            return page("Scriptlets", """
            <div class=sponsor>an ad</div><script>
            window.pruned = JSON.stringify(JSON.parse('{"ads":1,"content":2}'));
            </script><script>window.loops = 1;
            </script><script>
            addEventListener('message', event => { window.framed = event.data; });
            document.write('<iframe src="http://127.0.0.1:' + location.port + '/frame"></iframe>');
            </script>
            """)
        case "/frame":
            return page("Frame", "<script>var frameAds = false; parent.postMessage(String(frameAds), '*');</script>")
        case "/picture":
            return page("Picture", "<img src=/icon.png style='position:fixed;inset:0;width:100vw;height:100vh'>")
        case "/test.user.js": return Response("text/javascript; charset=utf-8", userscript)
        case "/require.js": return Response("text/javascript", "var requiredValue = 'required';")
        case "/note.txt": return Response("text/plain", "note-text")
        case "/update.user.js":
            return Response("text/javascript", "// ==UserScript==\n// @name Updater\n// @version 2.0\n// @grant none\n// ==/UserScript==\n")
        case "/big": return Response("text/plain", Data(repeating: UInt8(ascii: "x"), count: 300_000))
        case "/icon.png": return Response("image/png", icon)
        case "/filters.txt": return Response("text/plain", filters)
        case "/download":
            var download = Response("text/plain", "browser")
            download.headers = [("Content-Disposition", "attachment; filename=\"browser-test.txt\"")]
            return download
        case "/download-slow":
            var slow = Response("application/octet-stream", Data(count: 1 << 16))
            slow.headers = [("Content-Disposition", "attachment; filename=\"browser-slow.bin\"")]
            slow.promised = 100_000_000
            return slow
        case "/ad-banner.js": return Response("text/javascript", "// an ad")
        default:
            var missing = Response("text/plain", "not found")
            missing.status = "404 Not Found"
            return missing
        }
    }

    private static func page(_ title: String, _ body: String) -> Response {
        Response("text/html; charset=utf-8", "<!doctype html><title>\(title)</title><link rel=icon href=/icon.png>\(body)")
    }

    /// Runs on this server's pages (any port), with a @require and a
    /// @resource beside it, and fetches from the other host.
    private static let userscript = """
    // ==UserScript==
    // @name        Self Test
    // @namespace   browser.selftest
    // @version     1.0
    // @match       http://localhost/page/*
    // @require     /require.js
    // @resource    note /note.txt
    // @grant       GM_getValue
    // @grant       GM_setValue
    // @grant       GM_getResourceText
    // @grant       GM.xmlHttpRequest
    // @grant       GM_registerMenuCommand
    // ==/UserScript==
    const runs = GM_getValue('runs', 0);
    GM_setValue('runs', runs + 1);
    document.documentElement.dataset.userscript = 'ran ' + runs + ' ' + requiredValue + ' ' + GM_getResourceText('note');
    GM.xmlHttpRequest({url: 'http://127.0.0.1:' + location.port + '/page/Cross-Origin'})
      .then(r => { document.documentElement.dataset.xhr = r.status === 200 && r.responseText.includes('Cross Origin') ? 'ok' : 'bad ' + r.status; });
    GM_registerMenuCommand('Mark', () => { document.documentElement.dataset.menu = 'clicked'; });

    """

    /// A red square, 32 points a side.
    private static let icon: Data = {
        let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0 ..< 32 { for y in 0 ..< 32 { picture.setColor(.systemRed, atX: x, y: y) } }
        return picture.representation(using: .png, properties: [:])!
    }()

    /// The padding, one rule a page here can run into, a hide for one host, and a scriptlet for each host.
    private static let filters = Data(((0 ..< ruleCount - 1).map { "||ad-\($0).invalid^" } + [
        "/ad-banner.js",
        "localhost##.sponsor",
        "localhost##+js(json-prune, ads)",
        "127.0.0.1##+js(set, frameAds, true)",
        // A replacement that still contains what it replaces, as Google's does.
        "localhost##+js(rpnt, script, window.loops = 1, window.replaced = (window.replaced || 0) + 1; window.loops = 1)",
    ]).joined(separator: "\n").utf8)
}
#endif
