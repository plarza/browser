import Foundation

/// Pages visited: the address and the page's title, most recent first.
/// No times, no page contents; a site's icon is kept beside it while the
/// site is in here. It is there for about://history.
@MainActor
public final class History {
    public static let shared = History()

    public struct Visit: Codable, Equatable {
        public var url: String
        public var title: String
        /// How many times it was visited, for ranking suggestions.
        public var count = 1
    }

    private var visits: [Visit]
    private var dirty = false

    private init() {
        visits = Store.read([Visit].self, "history.json") ?? []
    }

    func add(_ url: URL) {
        let text = url.absoluteString
        let old = visits.first { $0.url == text }
        visits.removeAll { $0.url == text }
        visits.insert(Visit(url: text, title: old?.title ?? "", count: (old?.count ?? 0) + 1), at: 0)
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
        if let host = URL(string: url)?.host?.lowercased(), !knows(host: host) { Favicons.shared.forget(host: host) }
        save()
    }

    public func clear() {
        visits = []
        Favicons.shared.forgetAll()
        save()
    }

    /// Whether any visit is to `host`.
    func knows(host: String) -> Bool {
        visits.contains { URL(string: $0.url)?.host?.lowercased() == host }
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

    /// What the address field fills in as you type, as Chrome and Safari
    /// do: a site you've been to whose name starts with what you typed
    /// (`git` → `github.com`), the one you visit most; once you type a `/`,
    /// a whole address that starts with it.
    public func autofill(_ typed: String) -> String? {
        let typed = typed.lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        if typed.contains("/") {
            return visits.lazy.map { History.bare($0.url) }.first { $0.lowercased().hasPrefix(typed) && $0.count > typed.count }
        }
        var hosts: [String: Int] = [:]
        for visit in visits {
            guard let host = URL(string: visit.url)?.host?.lowercased() else { continue }
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if bare.hasPrefix(typed), bare.count > typed.count { hosts[bare, default: 0] += visit.count }
        }
        return hosts.max { ($0.value, -$0.key.count) < ($1.value, -$1.key.count) }?.key
    }

    /// Pages for the list under the address field, best first. A page ranks
    /// higher the earlier in its address or title the words match (the
    /// start of the site's name best, then the start of any word, then
    /// anywhere), and the more and the more recently it was visited.
    public func suggest(_ query: String, limit: Int = 6) -> [Visit] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var scored: [(Double, Visit)] = []
        for (age, visit) in visits.enumerated() {
            let bare = History.bare(visit.url).lowercased()
            let title = visit.title.lowercased()
            var score = 0.0
            for word in words {
                if bare.hasPrefix(word) {
                    score += 100
                } else if History.startsWord(word, in: bare) || History.startsWord(word, in: title) {
                    score += 50
                } else if bare.contains(word) || title.contains(word) {
                    score += 10
                } else {
                    score = -1
                    break
                }
            }
            guard score > 0 else { continue }
            score += 15 * log2(Double(visit.count) + 1) - Double(age) * 0.02
            scored.append((score, visit))
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    static func startsWord(_ word: String, in text: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: word, range: start ..< text.endIndex) {
            if range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter && !text[text.index(before: range.lowerBound)].isNumber {
                return true
            }
            start = text.index(after: range.lowerBound)
        }
        return false
    }

    public static func bare(_ url: String) -> String {
        var s = url
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s
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
}

/// The open tabs' addresses, so they come back after a relaunch, each in a
/// new identity like any other load.
@MainActor
public enum OpenTabs {
    public typealias Kept = (id: UUID, seed: UInt64)

    /// Each tab's address and, for a Persist tab, its jar on disk and seed.
    public static func save(_ tabs: [(url: URL, kept: Kept?)], selected: Int) {
        Store.write(Saved(tabs: tabs.map { .init(url: $0.url, jar: $0.kept?.id, seed: $0.kept?.seed) }, selected: selected), "tabs.json")
    }

    public static func restore() -> (tabs: [(url: URL, kept: Kept?)], selected: Int) {
        guard let saved = Store.read(Saved.self, "tabs.json") else { return ([], 0) }
        return (saved.tabs.map { tab in (tab.url, tab.jar.flatMap { id in tab.seed.map { (id, $0) } }) }, saved.selected)
    }

    private struct Saved: Codable {
        struct Tab: Codable { var url: URL; var jar: UUID?; var seed: UInt64? }
        var tabs: [Tab]
        var selected: Int
    }
}
