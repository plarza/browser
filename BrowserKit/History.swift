import Foundation
import SQLite3

/// Pages visited: the address, the page's title, how many times and when
/// it was last visited, and its frecency. No page contents; a site's icon is
/// kept beside it while the site is in here. Also what was typed before
/// picking a page from the list under the address field. It feeds the
/// address field and about://history.
///
/// Kept in SQLite (history.db), read and written on one background queue,
/// so a lookup never holds up typing.
@MainActor
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

        var weight: Double {
            switch self {
            case .typed: 2
            case .link: 1
            case .reload: Frecency.low
            }
        }
    }

    /// What the address field shows for what's been typed.
    public struct Completion: Sendable {
        /// The whole site name or address to fill in, if any.
        public var fill: String?
        /// Pages for the list under the field, best first.
        public var pages: [Visit]
    }

    private let queue = DispatchQueue(label: "Browser.History", qos: .userInitiated)
    private nonisolated(unsafe) var db: Database?

    private init() {
        queue.async { [self] in db = Database(Store.url("history.db"), today: Frecency.today()) }
    }

    func add(_ url: URL, as kind: Kind) {
        let today = Frecency.today()
        queue.async { [self] in db?.add(url, weight: kind.weight, today: today) }
    }

    /// A page that sent itself on to another without being clicked away
    /// from (a script redirect): its visit counts as little as a reload's.
    func redirected(from url: URL) {
        let today = Frecency.today()
        queue.async { [self] in db?.redirected(from: url.absoluteString, today: today) }
    }

    func setTitle(_ title: String, for url: URL) {
        guard !title.isEmpty else { return }
        queue.async { [self] in db?.setTitle(title, for: url.absoluteString) }
    }

    /// `url` was picked from the list under the address field after typing
    /// `input`: next time that input, or the start of it, puts it first.
    public func picked(_ url: String, after input: String) {
        let input = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        let today = Frecency.today()
        queue.async { [self] in db?.picked(url, after: input, today: today) }
    }

    public func remove(_ url: String) {
        queue.sync { db?.remove(url) }
        if let host = URL(string: url)?.host?.lowercased(), !knows(host: host) { Favicons.shared.forget(host: host) }
    }

    public func clear() {
        queue.sync { db?.clear() }
        Favicons.shared.forgetAll()
    }

    /// Whether any visit is to `host`.
    func knows(host: String) -> Bool {
        queue.sync { db?.knows(host: host) ?? false }
    }

    /// As you type: what to fill in (as Chrome and Safari do, a site you've
    /// been to whose name starts with what you typed, `git` → `github.com`,
    /// the one with the highest frecency; once you type a `/`, a whole
    /// address that starts with it) and the best matching pages.
    ///
    /// Pages picked before after typing this, or more, come first. The rest
    /// rank by how early in their address or title the words match (the
    /// start of the address best, then the start of any word, then
    /// anywhere), plus their frecency.
    public func complete(_ typed: String, limit: Int = 8) async -> Completion {
        let today = Frecency.today()
        return await withCheckedContinuation { done in
            queue.async { [self] in
                done.resume(returning: Completion(fill: db?.autofill(typed, today: today),
                                                  pages: db?.suggest(typed, limit: limit, today: today) ?? []))
            }
        }
    }

    /// Every word must appear somewhere in the address or the title. Most
    /// recent first.
    public func search(_ query: String, limit: Int = 500) -> [Visit] {
        queue.sync { db?.search(query, limit: limit) ?? [] }
    }

    public nonisolated static func bare(_ url: String) -> String {
        var s = url
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        return s
    }
}

/// Frecency, as Firefox has it: every visit adds its weight to a page's
/// score, and the score halves every 30 days. What's kept is the day (since
/// 1970) the score falls to 1, `day + ln(score) / λ`, so pages sort by it
/// directly, with nothing to recalculate as time passes.
enum Frecency {
    static let λ = log(2.0) / 30
    /// A reload's or a redirect source's weight.
    static let low = 0.25
    /// Points in a suggestion's rank per day of frecency: twice the score is
    /// 30 days, 15 points.
    static let points = 0.5

    nonisolated static func today() -> Double { Date().timeIntervalSince1970 / 86400 }
}

/// history.db. Used only on History's queue.
///
/// `visits`: each row keeps, beside the address and title, lowercased copies
/// for matching: `bare` (the address without scheme or www.), `ltitle`, and
/// `words` (both with every non-letter, non-digit made a space, so the start
/// of a word is a space followed by it). `host` is the address's host and
/// `site` the same without www., for completing site names.
///
/// `picks`: what was typed before picking a page from the list. `uses` goes
/// up towards 10 with each pick (×0.9 + 1, as Firefox does), and falls by
/// 2.5% a day since `day`; under 0.1 (about 90 days unused) it's deleted.
private final class Database {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init?(_ file: URL, today: Double) {
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            NSLog("History: can't open \(file.path): \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_close(db)
            return nil
        }
        // Deleted rows are overwritten with zeros, not left in free pages.
        exec("""
        PRAGMA secure_delete = ON;
        CREATE TABLE IF NOT EXISTS visits(
            id INTEGER PRIMARY KEY,
            url TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL DEFAULT '',
            bare TEXT NOT NULL,
            ltitle TEXT NOT NULL DEFAULT '',
            words TEXT NOT NULL,
            host TEXT NOT NULL,
            site TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 1,
            last REAL NOT NULL,
            frecency REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS visits_last ON visits(last);
        CREATE INDEX IF NOT EXISTS visits_host ON visits(host);
        CREATE INDEX IF NOT EXISTS visits_site ON visits(site);
        CREATE INDEX IF NOT EXISTS visits_frecency ON visits(frecency);
        CREATE TABLE IF NOT EXISTS picks(
            input TEXT NOT NULL,
            url TEXT NOT NULL,
            uses REAL NOT NULL,
            day REAL NOT NULL,
            PRIMARY KEY(input, url)
        ) WITHOUT ROWID;
        """)
        run("DELETE FROM picks WHERE uses * pow(0.975, ?1 - day) < 0.1", [today])
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    // MARK: Writing

    func add(_ url: URL, weight: Double, today: Double) {
        let text = url.absoluteString
        let bare = History.bare(text).lowercased()
        let host = url.host?.lowercased() ?? ""
        run("""
        INSERT INTO visits(url, bare, words, host, site, last, frecency)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6 * 86400, ?6 + ln(?7) / ?8)
        ON CONFLICT(url) DO UPDATE SET count = count + 1, last = excluded.last,
            frecency = ?6 + ln(exp(?8 * (frecency - ?6)) + ?7) / ?8
        """, [text, bare, Self.words(bare, ""), host, Self.site(host), today, weight, Frecency.λ])
    }

    /// Takes back the difference between a link's weight and a low one.
    func redirected(from url: String, today: Double) {
        run("UPDATE visits SET frecency = ?2 + ln(max(exp(?3 * (frecency - ?2)) - ?4, 0.05)) / ?3 WHERE url = ?1",
            [url, today, Frecency.λ, History.Kind.link.weight - Frecency.low])
    }

    func setTitle(_ title: String, for url: String) {
        let lower = title.lowercased()
        run("UPDATE visits SET title = ?2, ltitle = ?3, words = ?4 WHERE url = ?1 AND title != ?2",
            [url, title, lower, Self.words(History.bare(url).lowercased(), lower)])
    }

    func picked(_ url: String, after input: String, today: Double) {
        run("""
        INSERT INTO picks(input, url, uses, day) VALUES(?1, ?2, 1, ?3)
        ON CONFLICT(input, url) DO UPDATE SET uses = min(10, uses * pow(0.975, ?3 - day) * 0.9 + 1), day = ?3
        """, [input, url, today])
    }

    func remove(_ url: String) {
        run("DELETE FROM visits WHERE url = ?1", [url])
        run("DELETE FROM picks WHERE url = ?1", [url])
    }

    func clear() {
        exec("DELETE FROM visits; DELETE FROM picks; VACUUM;")
    }

    // MARK: Reading

    func knows(host: String) -> Bool {
        var found = false
        rows("SELECT 1 FROM visits WHERE host = ?1 LIMIT 1", [host]) { _ in found = true }
        return found
    }

    func autofill(_ typed: String, today: Double) -> String? {
        let typed = typed.lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        // Everything that starts with `typed`, as a range the index can use.
        let end = typed + "\u{10FFFF}"
        var fill: String?
        if typed.contains("/") {
            rows("SELECT url FROM visits WHERE bare > ?1 AND bare < ?2 ORDER BY frecency DESC LIMIT 1", [typed, end]) {
                fill = History.bare($0.text(0))
            }
        } else {
            // A site's score is the sum of its pages' scores today.
            rows("""
            SELECT site FROM visits WHERE site > ?1 AND site < ?2
            GROUP BY site ORDER BY sum(exp(?3 * (frecency - ?4))) DESC, length(site) LIMIT 1
            """, [typed, end, Frecency.λ, today]) { fill = $0.text(0) }
        }
        return fill
    }

    func suggest(_ query: String, limit: Int, today: Double) -> [History.Visit] {
        let words = Self.split(query)
        guard !words.isEmpty else { return [] }
        let typed = words.joined(separator: " ")
        // Picked before: at most half the list, so the rest still shows.
        var found: [History.Visit] = []
        rows("""
        SELECT v.url, v.title, v.count, max(p.uses * pow(0.975, ?2 - p.day) * (1 + (p.input = ?1))) AS rank
        FROM picks p JOIN visits v ON v.url = p.url
        WHERE p.input >= ?1 AND p.input < ?3
        GROUP BY v.url HAVING rank >= 0.1 ORDER BY rank DESC, v.frecency DESC LIMIT ?4
        """, [typed, today, typed + "\u{10FFFF}", (limit + 1) / 2]) {
            found.append(History.Visit(url: $0.text(0), title: $0.text(1), count: $0.int(2)))
        }
        let seen = Set(found.map(\.url))
        let wanted = limit - found.count
        guard wanted > 0 else { return found }

        // The rest, read in frecency order: a page's rank is its match
        // points plus its frecency's, so once the best match points a page
        // could have can't lift it past the last of the best so far, no page
        // after it can do better, and the scan stops.
        var args: [Any] = []
        var filters: [String] = []
        var points: [String] = []
        for word in words {
            let w = args.count + 1
            args.append(word)
            args.append(" " + Self.normalise(word).trimmingCharacters(in: .whitespaces))
            filters.append("(instr(bare, ?\(w)) > 0 OR instr(ltitle, ?\(w)) > 0)")
            points.append("CASE WHEN substr(bare, 1, length(?\(w))) = ?\(w) THEN 100 WHEN instr(words, ?\(w + 1)) > 0 THEN 50 ELSE 10 END")
        }
        let sql = """
        SELECT url, title, count, frecency, \(points.joined(separator: " + ")) FROM visits
        WHERE \(filters.joined(separator: " AND ")) ORDER BY frecency DESC
        """
        let most = 100.0 * Double(words.count)
        var best: [(rank: Double, visit: History.Visit)] = []
        scan(sql, args) { row in
            let frecency = Frecency.points * row.double(3)
            if best.count == wanted, frecency + most <= best[wanted - 1].rank { return false }
            let url = row.text(0)
            guard !seen.contains(url) else { return true }
            let rank = frecency + row.double(4)
            guard best.count < wanted || rank > best[wanted - 1].rank else { return true }
            let visit = History.Visit(url: url, title: row.text(1), count: row.int(2))
            best.insert((rank, visit), at: best.firstIndex { $0.rank < rank } ?? best.count)
            if best.count > wanted { best.removeLast() }
            return true
        }
        return found + best.map(\.visit)
    }

    func search(_ query: String, limit: Int) -> [History.Visit] {
        let words = Self.split(query)
        var args: [Any] = [limit]
        let filters = words.map { word -> String in
            args.append(word)
            return "(instr(bare, ?\(args.count)) > 0 OR instr(ltitle, ?\(args.count)) > 0)"
        }
        let filter = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
        var found: [History.Visit] = []
        rows("SELECT url, title, count FROM visits \(filter) ORDER BY last DESC LIMIT ?1", args) {
            found.append(History.Visit(url: $0.text(0), title: $0.text(1), count: $0.int(2)))
        }
        return found
    }

    // MARK: Text

    private static func split(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalise(_ text: String) -> String {
        String(text.map { $0.isLetter || $0.isNumber ? $0 : " " })
    }

    private static func words(_ bare: String, _ title: String) -> String {
        " " + normalise(bare) + " " + normalise(title)
    }

    private static func site(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: SQLite

    struct Row {
        let statement: OpaquePointer
        func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            NSLog("History: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    private func run(_ sql: String, _ args: [Any]) {
        scan(sql, args) { _ in true }
    }

    private func rows(_ sql: String, _ args: [Any], _ each: (Row) -> Void) {
        scan(sql, args) { each($0); return true }
    }

    /// Steps through the rows until `each` returns false.
    private func scan(_ sql: String, _ args: [Any], _ each: (Row) -> Bool) {
        guard let statement = prepare(sql) else { return }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, transient)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, index, value)
            default: sqlite3_bind_null(statement, index)
            }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { if each(Row(statement: statement)) { continue } else { return } }
            if step != SQLITE_DONE { NSLog("History: \(String(cString: sqlite3_errmsg(db)))") }
            return
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK else {
            NSLog("History: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        statements[sql] = statement
        return statement
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
