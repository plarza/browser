import Foundation

/// Pages visited: the address and the page's title, most recent first.
/// No times, no icons, no page contents. It is there for the field to
/// finish what you type, and for about://history.
@MainActor
public final class History {
    public static let shared = History()

    public struct Visit: Codable, Equatable {
        public var url: String
        public var title: String
    }

    private var visits: [Visit]
    private var dirty = false
    private static let limit = 10000

    private init() {
        if let visits = Store.read([Visit].self, "history.json") {
            self.visits = visits
        } else {
            // Before titles were kept: addresses only.
            visits = (Store.read([String].self, "history.json") ?? []).map { Visit(url: $0, title: "") }
        }
    }

    func add(_ url: URL) {
        let text = url.absoluteString
        let title = visits.first { $0.url == text }?.title ?? ""
        visits.removeAll { $0.url == text }
        visits.insert(Visit(url: text, title: title), at: 0)
        if visits.count > History.limit { visits.removeLast(visits.count - History.limit) }
        save()
    }

    func setTitle(_ title: String, for url: URL) {
        let text = url.absoluteString
        guard !title.isEmpty, let i = visits.firstIndex(where: { $0.url == text }), visits[i].title != title else { return }
        visits[i].title = title
        save()
    }

    public func remove(_ url: String) {
        visits.removeAll { $0.url == url }
        save()
    }

    public func clear() {
        visits = []
        save()
    }

    private func save() {
        guard !dirty else { return }
        dirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.dirty = false
            Store.write(self.visits, "history.json")
        }
    }

    /// Every word must appear somewhere in the address or the title.
    public func search(_ query: String, limit: Int = 500) -> [Visit] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Array(visits.prefix(limit)) }
        return Array(visits.lazy.filter { visit in
            let text = (visit.url + " " + visit.title).lowercased()
            return words.allSatisfy(text.contains)
        }.prefix(limit))
    }

    /// The most recent address that starts with what was typed, ignoring
    /// the scheme and `www.`.
    public func complete(_ typed: String) -> String? {
        let typed = typed.lowercased()
        guard typed.count >= 2, !typed.contains(" ") else { return nil }
        for visit in visits {
            let bare = History.bare(visit.url)
            if bare.lowercased().hasPrefix(typed) { return bare }
        }
        return nil
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
