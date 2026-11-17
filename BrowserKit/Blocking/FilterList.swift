import Foundation

/// A filter list as fetched: its text, and where it came from.
struct FilterList: Sendable {
    let url: URL
    let text: String

    /// uBlock Origin's own lists, the only ones whose `trusted-` scriptlets
    /// (which can run any code) uBlock Origin runs, and lists served from
    /// this Mac itself.
    var isTrusted: Bool {
        url.host?.lowercased() == "ublockorigin.github.io"
            || url.absoluteString.lowercased().contains("/ublockorigin/uassets/")
            || Site.isLoopback(url.host)
    }
}
