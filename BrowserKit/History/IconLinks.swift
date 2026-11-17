import WebKit

/// The icons a page offers: its own `<link rel=icon>`, read from WebKit's
/// client world, which the page can't see or detect.
@MainActor
enum IconLinks {
    private static let script = """
    [...document.querySelectorAll('link[rel~="icon" i], link[rel="apple-touch-icon" i], link[rel="shortcut icon" i]')]
      .map(l => [l.href, l.getAttribute('sizes') || '', l.type || ''])
    """

    /// Where the page in `webView` says its icons are, the one that suits a
    /// tab best first.
    static func read(from webView: WKWebView) async -> [URL] {
        let links = (try? await webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)) as? [[String]] ?? []
        var icons: [(url: URL, score: Int)] = []
        for link in links {
            guard let href = link.first, let url = URL(string: href), url.isWeb else { continue }
            icons.append((url, score(sizes: link.count > 1 ? link[1] : "", type: link.count > 2 ? link[2] : "", url: url)))
        }
        icons.sort { $0.score > $1.score }
        return icons.map(\.url)
    }

    /// 32 px and up is what a tab wants; SVG scales to anything.
    static func score(sizes: String, type: String, url: URL) -> Int {
        if type.contains("svg") || url.pathExtension.lowercased() == "svg" { return 1000 }
        let size = sizes.split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max() ?? 16
        return size >= 32 ? 500 - abs(size - 64) : size
    }
}
