import Foundation

/// Core's own pages: about://history, about://settings and about://help.
/// They are native views the shell shows in the tab; the tab only keeps
/// their address, for the field and for back and forward.
public enum InternalPage {
    public static let pages = ["history", "settings", "help"]

    /// The page an about: address names, if it is one of Core's.
    public static func page(_ url: URL?) -> String? {
        guard let url, url.scheme == "about" else { return nil }
        let name = url.host ?? url.absoluteString.replacingOccurrences(of: "about:", with: "")
        return pages.contains(name) ? name : nil
    }

    public static func address(_ page: String) -> URL { URL(string: "about://\(page)")! }
}
