#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif
import Observation

// STUB: the public surface the shells and the rest of BrowserKit rely on.
// The bodies are to be rebuilt; the signatures here are the contract.
@MainActor @Observable
public final class Favicons {
    public static let shared = Favicons()

    /// The site's icon, if it is known. Observable: a view reading it is
    /// told when an icon arrives.
    public func icon(for url: URL?) -> PlatformImage? { nil }
    /// Browser's own pages use the grey glyph on a transparent background.
    public static let browser: PlatformImage? = nil
    /// For a site not open in any tab (Settings' lists): its /favicon.ico,
    /// fetched the same cookie-free way, once.
    public func fetch(site url: URL) {}
    /// An icon is being fetched.
    public var isFetching: Bool { false }

    func load(for tab: Tab) {}
    func forget(host: String) {}
    func forgetAll() {}
}
