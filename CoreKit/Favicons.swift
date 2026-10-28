import AppKit
import CryptoKit
import WebKit

/// Site icons for the tabs. The page's own `<link rel=icon>` is read from
/// WebKit's client world, which the page can't see or detect, and fetched
/// with no cookies, no cache on disk and Safari's user agent: what any
/// browser asks for a favicon. An icon is kept on disk only for a site that
/// is already in History or on the cookie list, so the disk says nothing
/// those don't; removing the site from History removes its icon, and
/// clearing History clears them all. A kept icon is never fetched again,
/// which is one request fewer for a site to see.
@MainActor
public final class Favicons {
    public static let shared = Favicons()
    public static let changed = Notification.Name("CoreFaviconChanged")

    private var icons: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(Engine.applicationName)",
            "Accept": "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        return URLSession(configuration: config)
    }()

    public func icon(for url: URL?) -> NSImage? {
        if InternalPage.page(url) != nil { return Favicons.core }
        guard let host = url?.host?.lowercased() else { return nil }
        if let icon = icons[host] { return icon }
        if let data = try? Data(contentsOf: file(for: host)), let image = NSImage(data: data), image.isValid {
            icons[host] = image
            return image
        }
        return nil
    }

    /// Core's own pages use the grey glyph on a transparent background.
    public static let core: NSImage? = {
        guard let url = Bundle.main.url(forResource: "C", withExtension: "svg"), let glyph = NSImage(contentsOf: url) else { return nil }
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            glyph.draw(in: rect)
            NSColor(white: 0.56, alpha: 1).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }()

    static var folder: URL { Store.directory.appendingPathComponent("Favicons", isDirectory: true) }

    /// Named by a hash of the host, so a listing of the folder isn't a list of sites.
    public func file(for host: String) -> URL {
        let name = SHA256.hash(data: Data(("core.icon." + host).utf8)).map { String(format: "%02x", $0) }.joined()
        return Favicons.folder.appendingPathComponent(name)
    }

    private func keep(_ data: Data, host: String) {
        guard History.shared.knows(host: host) || Whitelist.domain(for: host) != nil else { return }
        try? FileManager.default.createDirectory(at: Favicons.folder, withIntermediateDirectories: true)
        try? data.write(to: file(for: host), options: [.atomic, .completeFileProtection])
    }

    func forget(host: String) {
        icons[host] = nil
        try? FileManager.default.removeItem(at: file(for: host))
    }

    func forgetAll() {
        icons = [:]
        try? FileManager.default.removeItem(at: Favicons.folder)
    }

    private static let script = """
    [...document.querySelectorAll('link[rel~="icon" i], link[rel="apple-touch-icon" i], link[rel="shortcut icon" i]')]
      .map(l => [l.href, l.getAttribute('sizes') || '', l.type || ''])
    """

    func load(for tab: Tab) {
        guard let url = tab.url, url.scheme == "https" || url.scheme == "http", let host = url.host?.lowercased(), icon(for: url) == nil, !loading.contains(host) else { return }
        loading.insert(host)
        tab.webView.evaluateJavaScript(Favicons.script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            var candidates: [(URL, Int)] = []
            if case .success(let value) = result, let links = value as? [[String]] {
                for link in links {
                    guard let href = link.first, let icon = URL(string: href), icon.scheme == "https" || icon.scheme == "http" else { continue }
                    candidates.append((icon, Favicons.score(sizes: link.count > 1 ? link[1] : "", type: link.count > 2 ? link[2] : "", url: icon)))
                }
            }
            candidates.sort { $0.1 > $1.1 }
            var fallback = URLComponents()
            fallback.scheme = url.scheme
            fallback.host = url.host
            fallback.port = url.port
            fallback.path = "/favicon.ico"
            if let ico = fallback.url { candidates.append((ico, 0)) }
            Task { await self.fetch(candidates.map(\.0), host: host) }
        }
    }

    /// For a site not open in any tab (Settings' lists): its /favicon.ico,
    /// fetched the same cookie-free way, once.
    public func fetch(site url: URL) {
        guard let host = url.host?.lowercased(), icon(for: url) == nil, !loading.contains(host),
              let ico = URL(string: "https://\(host)/favicon.ico") else { return }
        loading.insert(host)
        Task { await fetch([ico], host: host) }
    }

    /// 32 px and up is what a tab wants; SVG scales to anything.
    static func score(sizes: String, type: String, url: URL) -> Int {
        if type.contains("svg") || url.pathExtension.lowercased() == "svg" { return 1000 }
        let size = sizes.split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max() ?? 16
        return size >= 32 ? 500 - abs(size - 64) : size
    }

    private func fetch(_ candidates: [URL], host: String) async {
        defer { loading.remove(host) }
        for candidate in candidates.prefix(4) {
            guard let (data, response) = try? await session.data(from: candidate),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000,
                  let image = NSImage(data: data), image.isValid, image.size.width > 0
            else { continue }
            icons[host] = image
            keep(data, host: host)
            NotificationCenter.default.post(name: Favicons.changed, object: host)
            return
        }
    }
}
