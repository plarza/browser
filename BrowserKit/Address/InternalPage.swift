import Foundation

/// Browser's own pages: about://history, about://downloads, about://settings,
/// about://userscripts and about://help. They are native views the shell
/// shows in the tab; the tab only keeps their address, for the field and
/// for back and forward.
public enum InternalPage: String, CaseIterable, Sendable {
    case history, downloads, settings, userscripts, help

    /// The page an about: address names, if it is one of Browser's.
    public init?(_ url: URL?) {
        guard let url, url.scheme == "about", let name = url.host, let page = InternalPage(rawValue: name) else { return nil }
        self = page
    }

    public var url: URL { URL(string: "about://\(rawValue)")! }
    public var title: String { rawValue.capitalized }
}
