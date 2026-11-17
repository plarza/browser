#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif
import Observation

/// Site icons for the tabs. The page's own `<link rel=icon>` is read from
/// WebKit's client world, which the page can't see or detect, and fetched
/// with no cookies, no cache on disk and Safari's user agent: what any
/// browser asks for a favicon. An icon is kept on disk only for a site that
/// is already in History or on the whitelist, so the disk says nothing
/// those don't; removing the site from History removes its icon, and
/// clearing History clears them all. A kept icon is never fetched again,
/// which is one request fewer for a site to see.
@MainActor @Observable
public final class Favicons {
    public static let shared = Favicons()

    /// Bumped when an icon arrives or goes. `icon(for:)` reads it, which is
    /// how a view showing an icon is told to ask again.
    private var version = 0
    /// The icons in memory, by host. Not observed: one read from the disk
    /// was the site's icon all along, so finding it there is no news.
    @ObservationIgnored private var icons: [String: PlatformImage] = [:]
    /// Hosts whose kept icon has been looked for, so the disk is asked once.
    @ObservationIgnored private var looked: Set<String> = []
    /// Hosts whose icon is on its way. Not observed, so that a view asking
    /// for a fetch isn't told when one fails, and so asks only once.
    @ObservationIgnored private var loading: Set<String> = [] {
        didSet {
            let fetching = !loading.isEmpty
            if fetching != isFetching { isFetching = fetching }
        }
    }

    /// An icon is being fetched.
    public private(set) var isFetching = false

    @ObservationIgnored private let session = Engine.session(timeout: 15, headers: [
        "Accept": "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5",
        "Accept-Language": "en-US,en;q=0.9",
    ])

    // MARK: Showing

    /// The site's icon, if it is known. Observable: a view reading it is
    /// told when an icon arrives.
    public func icon(for url: URL?) -> PlatformImage? {
        if InternalPage(url) != nil { return Favicons.browser }
        guard let host = url?.host?.lowercased() else { return nil }
        _ = version
        if looked.insert(host).inserted { icons[host] = FaviconFiles.read(host).flatMap(Favicons.image) }
        return icons[host]
    }

    /// Browser's own pages use the grey glyph on a transparent background.
    public static let browser: PlatformImage? = {
        #if os(macOS)
        guard let url = Bundle.main.url(forResource: "B", withExtension: "svg"), let glyph = NSImage(contentsOf: url) else { return nil }
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            glyph.draw(in: rect)
            NSColor(white: 0.56, alpha: 1).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        #else
        return UIImage(named: "B")?.withTintColor(UIColor(white: 0.56, alpha: 1), renderingMode: .alwaysOriginal)
        #endif
    }()

    /// Where a host's icon is kept, if it is.
    public func file(for host: String) -> URL { FaviconFiles.file(for: host) }

    /// An icon from the bytes a site served, if they are a picture.
    private static func image(_ data: Data) -> PlatformImage? {
        guard let image = PlatformImage(data: data), image.size.width > 0 else { return nil }
        #if os(macOS)
        guard image.isValid else { return nil }
        #endif
        return image
    }

    // MARK: Fetching

    /// The icon of the page `tab` has just loaded, unless its site's is
    /// already known or on its way.
    func load(for tab: Tab) {
        guard let url = tab.url, url.isWeb, let host = url.host?.lowercased(), icon(for: url) == nil, !loading.contains(host) else { return }
        loading.insert(host)
        let page = tab.webView
        Task {
            var candidates = await IconLinks.read(from: page)
            // What a site with no link, or none that loads, is asked for.
            if let ico = URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL { candidates.append(ico) }
            await fetch(candidates, for: host)
        }
    }

    /// For a site not open in any tab (Settings' lists): its /favicon.ico,
    /// fetched the same cookie-free way, once.
    public func fetch(site url: URL) {
        guard let host = url.host?.lowercased(), icon(for: url) == nil, !loading.contains(host),
              let ico = URL(string: "https://\(host)/favicon.ico") else { return }
        loading.insert(host)
        Task { await fetch([ico], for: host) }
    }

    /// The first few candidates in turn, until one is a picture.
    private func fetch(_ candidates: [URL], for host: String) async {
        defer { loading.remove(host) }
        for candidate in candidates.prefix(4) {
            guard let (data, response) = try? await session.data(from: candidate),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000,
                  let image = Favicons.image(data)
            else { continue }
            icons[host] = image
            // On disk only for a site History or the whitelist already names.
            if History.shared.knows(host: host) || Whitelist.domain(for: host) != nil { FaviconFiles.keep(data, for: host) }
            version += 1
            return
        }
    }

    // MARK: Forgetting

    func forget(host: String) {
        icons[host] = nil
        FaviconFiles.remove(host)
        version += 1
    }

    func forgetAll() {
        icons = [:]
        FaviconFiles.removeAll()
        version += 1
    }
}
