import Foundation

/// The pages Browser itself shows in a tab when a load can't go on: a site
/// with no HTTPS, a page that keeps crashing.
enum Notice {
    private static let allowScheme = "browser-allow-http"

    /// The site has no HTTPS: say so, and offer this one load over HTTP.
    static func notSecure(_ url: URL, token: String) -> String {
        var allow = URLComponents()
        allow.scheme = allowScheme
        allow.path = token
        allow.queryItems = [URLQueryItem(name: "u", value: url.absoluteString)]
        return page(title: "Not secure", heading: "\(escape(url.host ?? url.absoluteString)) doesn't support HTTPS", body: """
        <p>The connection won't be encrypted.</p>
        <a class=button href="\(escape(allow.url?.absoluteString ?? ""))">Continue over HTTP</a>
        """)
    }

    /// The address "Continue over HTTP" leads to, if `url` is that button's
    /// on a notice made with `token`: a page can't forge one.
    static func httpAllowed(by url: URL, token: String) -> URL? {
        guard url.scheme?.lowercased() == allowScheme, url.absoluteString.hasPrefix("\(allowScheme):\(token)?") else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "u" }?.value.flatMap(URL.init(string:))
    }

    static func crashed(_ url: URL?) -> String {
        #if os(macOS)
        let how = "Press ⌘R to reload."
        #else
        let how = "Pull down to reload."
        #endif
        return page(title: "Crashed", heading: "\(escape(url?.host ?? "This page")) crashed", body: "<p>\(how)</p>")
    }

    private static func page(title: String, heading: String, body: String) -> String {
        """
        <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width"><title>\(title)</title>
        <style>
        :root{color-scheme:light dark;font:15px -apple-system,system-ui}
        body{max-width:32rem;margin:18vh auto;padding:0 1.5rem;line-height:1.5}
        h1{font-size:1.25rem;font-weight:600}
        a.button{display:inline-block;margin-top:1rem;padding:.45rem .9rem;border-radius:.5rem;border:1px solid #8886;color:inherit;text-decoration:none}
        </style>
        <h1>\(heading)</h1>
        \(body)
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
