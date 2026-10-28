import Foundation

/// Browser's own pages: about://history, about://downloads, about://settings
/// and about://help.
/// They are native views the shell shows in the tab; the tab only keeps
/// their address, for the field and for back and forward.
public enum InternalPage {
    public static let pages = ["history", "downloads", "settings", "help"]

    /// The page an about: address names, if it is one of Browser's.
    public static func page(_ url: URL?) -> String? {
        guard let url, url.scheme == "about", let name = url.host else { return nil }
        return pages.contains(name) ? name : nil
    }

    public static func address(_ page: String) -> URL { URL(string: "about://\(page)")! }
}
