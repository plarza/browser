import AppKit
import WebKit

/// Site icons for the tabs. The page's own `<link rel=icon>` is read from
/// WebKit's client world, which the page can't see or detect, and fetched
/// with no cookies, no cache on disk and Safari's user agent: what any
/// browser asks for a favicon. Icons live in memory only, by host, and are
/// gone when Core quits.
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
        guard let host = url?.host?.lowercased() else { return nil }
        return icons[host]
    }

    private static let script = """
    [...document.querySelectorAll('link[rel~="icon" i], link[rel="apple-touch-icon" i], link[rel="shortcut icon" i]')]
      .map(l => [l.href, l.getAttribute('sizes') || '', l.type || ''])
    """

    func load(for tab: Tab) {
        guard let url = tab.url, url.scheme == "https" || url.scheme == "http", let host = url.host?.lowercased(), icons[host] == nil, !loading.contains(host) else { return }
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
            NotificationCenter.default.post(name: Favicons.changed, object: host)
            return
        }
    }
}
