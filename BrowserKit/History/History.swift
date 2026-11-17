import Foundation
import Observation

/// Pages visited: the address, the page's title, how many times and when
/// it was last visited, and its frecency. No page contents; a site's icon is
/// kept beside it while the site is in here. Also what was typed before
/// picking a page from the list under the address field. It feeds the
/// address field and about://history.
///
/// Kept in SQLite (history.db), read and written on one background queue,
/// so a lookup never holds up typing.
@MainActor @Observable
public final class History {
    public static let shared = History()

    public struct Visit: Equatable, Sendable {
        public var url: String
        public var title: String
        /// How many times it was visited.
        public var count = 1
    }

    /// How a page was reached, which sets how much the visit counts.
    public enum Kind: Sendable {
        /// Typed or picked in the address field. Not a search.
        case typed
        /// A link, a page's own navigation, back or forward.
        case link
        /// A reload, or a tab reopened at launch.
        case reload
    }

    /// What the address field shows for what's been typed.
    public struct Completion: Sendable {
        /// The whole site name or address to fill in, if any.
        public var fill: String?
        /// Pages for the list under the field, best first.
        public var pages: [Visit]
    }

    /// Bumped whenever History changes, so a view showing it can keep up.
    /// A lookup made after the bump sees the change: it waits its turn
    /// behind it on the database's queue.
    public private(set) var version = 0

    @ObservationIgnored private let database = HistoryDatabase(Store.url("history.db"))

    private init() {
        let today = Frecency.today()
        database.write { $0.forgetFadedPicks(today: today) }
    }

    private func change(_ change: @escaping @Sendable (isolated HistoryDatabase) -> Void) {
        database.write(change)
        version += 1
    }

    // MARK: What tabs tell it

    func add(_ url: URL, as kind: Kind) {
        let today = Frecency.today()
        change { $0.add(url, weight: kind.weight, today: today) }
    }

    /// A page that sent itself on to another without being clicked away
    /// from (a script redirect): its visit counts as little as a reload's.
    func redirected(from url: URL) {
        let today = Frecency.today()
        change { $0.redirected(from: url.absoluteString, today: today) }
    }

    func setTitle(_ title: String, for url: URL) {
        guard !title.isEmpty else { return }
        change { $0.setTitle(title, for: url.absoluteString) }
    }

    /// The title History holds for this address, if it's in History.
    func title(for url: URL) -> String? {
        database.read { $0.title(for: url.absoluteString) }
    }

    /// Whether any visit is to `host`.
    func knows(host: String) -> Bool {
        database.read { $0.knows(host: host) }
    }

    // MARK: The address field

    /// As you type: what to fill in (the most frecent site whose name
    /// starts with what's typed, or after a `/` a whole address that does)
    /// and the best matching pages, those picked before for this first.
    /// Looked up off the main thread.
    public func complete(_ typed: String, limit: Int = 8) async -> Completion {
        await database.complete(typed, limit: limit, today: Frecency.today())
    }

    /// `url` was picked from the list under the address field after typing
    /// `input`: next time that input, or the start of it, puts it first.
    public func picked(_ url: String, after input: String) {
        let input = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        let today = Frecency.today()
        change { $0.picked(url, after: input, today: today) }
    }

    /// An address without its scheme and `www.`, as the field shows and matches it.
    public nonisolated static func bare(_ url: String) -> String {
        var bare = Substring(url)
        for scheme in ["https://", "http://"] where bare.hasPrefix(scheme) { bare.removeFirst(scheme.count) }
        if bare.hasPrefix("www.") { bare.removeFirst(4) }
        return String(bare)
    }

    // MARK: about://history

    /// Every word, across addresses and titles; most recent first.
    public func search(_ query: String, limit: Int = 500) async -> [Visit] {
        await database.search(query, limit: limit)
    }

    /// The page goes, with what was typed to pick it, and its site's icon
    /// if that was the site's last page.
    public func remove(_ url: String) {
        change { $0.remove(url) }
        if let host = URL(string: url)?.host?.lowercased(), !knows(host: host) { Favicons.shared.forget(host: host) }
    }

    /// Everything goes: every page, every pick, every icon.
    public func clear() {
        change { $0.clear() }
        Favicons.shared.forgetAll()
    }
}
