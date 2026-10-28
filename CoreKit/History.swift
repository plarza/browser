import Foundation

/// Addresses visited, and nothing else: no titles, no times, no icons.
/// It is there for the field to finish what you type.
@MainActor
public final class History {
    public static let shared = History()

    private var urls: [String]
    private var dirty = false
    private static let limit = 5000

    private init() {
        urls = Store.read([String].self, "history.json") ?? []
    }

    func add(_ url: URL) {
        let text = url.absoluteString
        urls.removeAll { $0 == text }
        urls.insert(text, at: 0)
        if urls.count > History.limit { urls.removeLast(urls.count - History.limit) }
        guard !dirty else { return }
        dirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.dirty = false
            Store.write(self.urls, "history.json")
        }
    }

    /// The most recent address that starts with what was typed, ignoring
    /// the scheme and `www.`.
    public func complete(_ typed: String) -> String? {
        let typed = typed.lowercased()
        guard typed.count >= 2, !typed.contains(" ") else { return nil }
        for url in urls {
            let bare = History.bare(url)
            if bare.lowercased().hasPrefix(typed) { return bare }
        }
        return nil
    }

    public func matches(_ typed: String, limit: Int = 8) -> [String] {
        let typed = typed.lowercased()
        guard !typed.isEmpty else { return [] }
        return Array(urls.lazy.filter { History.bare($0).lowercased().contains(typed) }.prefix(limit))
    }

    static func bare(_ url: String) -> String {
        var s = url
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s
    }
}

/// The open tabs' addresses, so they come back after a relaunch, each in a
/// new identity like any other load.
@MainActor
public enum OpenTabs {
    public static func save(_ urls: [URL], selected: Int) {
        Store.write(Saved(urls: urls.map(\.absoluteString), selected: selected), "tabs.json")
    }

    public static func restore() -> (urls: [URL], selected: Int) {
        guard let saved = Store.read(Saved.self, "tabs.json") else { return ([], 0) }
        return (saved.urls.compactMap(URL.init(string:)), saved.selected)
    }

    private struct Saved: Codable {
        var urls: [String]
        var selected: Int
    }
}
