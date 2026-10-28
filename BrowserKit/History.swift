import Foundation
import SQLite3

/// Pages visited: the address, the page's title, how many times and when
/// it was last visited. No page contents; a site's icon is kept beside it
/// while the site is in here. It feeds the address field and about://history.
///
/// Kept in SQLite (history.db), read and written on one background queue,
/// so a lookup never holds up typing.
@MainActor
public final class History {
    public static let shared = History()

    public struct Visit: Equatable, Sendable {
        public var url: String
        public var title: String
        /// How many times it was visited, for ranking suggestions.
        public var count = 1
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
        queue.async { [self] in db = Database(Store.url("history.db")) }
    }

    func add(_ url: URL) {
        let now = Date().timeIntervalSince1970
        queue.async { [self] in db?.add(url, at: now) }
    }

    func setTitle(_ title: String, for url: URL) {
        guard !title.isEmpty else { return }
        queue.async { [self] in db?.setTitle(title, for: url.absoluteString) }
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
    /// the one you visit most; once you type a `/`, the latest whole address
    /// that starts with it) and the best matching pages.
    ///
    /// Pages rank higher the earlier in their address or title the words
    /// match (the start of the site's name best, then the start of any word,
    /// then anywhere), the more often they were visited, and the more
    /// recently.
    public func complete(_ typed: String, limit: Int = 6) async -> Completion {
        let now = Date().timeIntervalSince1970
        return await withCheckedContinuation { done in
            queue.async { [self] in
                done.resume(returning: Completion(fill: db?.autofill(typed), pages: db?.suggest(typed, limit: limit, now: now) ?? []))
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

/// history.db. Used only on History's queue.
///
/// Each row keeps, beside the address and title, lowercased copies for
/// matching: `bare` (the address without scheme or www.), `ltitle`, and
/// `words` (both with every non-letter, non-digit made a space, so the start
/// of a word is a space followed by it). `host` is the address's host and
/// `site` the same without www., for completing site names.
private final class Database {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init?(_ file: URL) {
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
            last REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS visits_last ON visits(last);
        CREATE INDEX IF NOT EXISTS visits_host ON visits(host);
        CREATE INDEX IF NOT EXISTS visits_site ON visits(site);
        """)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    // MARK: Writing

    func add(_ url: URL, at time: Double) {
        let text = url.absoluteString
        let bare = History.bare(text).lowercased()
        let host = url.host?.lowercased() ?? ""
        run("""
        INSERT INTO visits(url, bare, words, host, site, last) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
        ON CONFLICT(url) DO UPDATE SET count = count + 1, last = excluded.last
        """, [text, bare, Self.words(bare, ""), host, Self.site(host), time])
    }

    func setTitle(_ title: String, for url: String) {
        let lower = title.lowercased()
        run("UPDATE visits SET title = ?2, ltitle = ?3, words = ?4 WHERE url = ?1 AND title != ?2",
            [url, title, lower, Self.words(History.bare(url).lowercased(), lower)])
    }

    func remove(_ url: String) {
        run("DELETE FROM visits WHERE url = ?1", [url])
    }

    func clear() {
        exec("DELETE FROM visits; VACUUM;")
    }

    // MARK: Reading

    func knows(host: String) -> Bool {
        var found = false
        rows("SELECT 1 FROM visits WHERE host = ?1 LIMIT 1", [host]) { _ in found = true }
        return found
    }

    func autofill(_ typed: String) -> String? {
        let typed = typed.lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        // Everything that starts with `typed`, as a range the index can use.
        let end = typed + "\u{10FFFF}"
        var fill: String?
        if typed.contains("/") {
            rows("SELECT url FROM visits WHERE bare > ?1 AND bare < ?2 ORDER BY last DESC LIMIT 1", [typed, end]) {
                fill = History.bare($0.text(0))
            }
        } else {
            rows("""
            SELECT site FROM visits WHERE site > ?1 AND site < ?2
            GROUP BY site ORDER BY sum(count) DESC, length(site) LIMIT 1
            """, [typed, end]) { fill = $0.text(0) }
        }
        return fill
    }

    func suggest(_ query: String, limit: Int, now: Double) -> [History.Visit] {
        let words = Self.split(query)
        guard !words.isEmpty else { return [] }
        var args: [Any] = [limit, now]
        var filters: [String] = []
        var scores: [String] = []
        for word in words {
            let w = args.count + 1
            args.append(word)
            args.append(" " + Self.normalise(word).trimmingCharacters(in: .whitespaces))
            filters.append("(instr(bare, ?\(w)) > 0 OR instr(ltitle, ?\(w)) > 0)")
            scores.append("CASE WHEN substr(bare, 1, length(?\(w))) = ?\(w) THEN 100 WHEN instr(words, ?\(w + 1)) > 0 THEN 50 ELSE 10 END")
        }
        let sql = """
        SELECT url, title, count FROM visits WHERE \(filters.joined(separator: " AND "))
        ORDER BY \(scores.joined(separator: " + ")) + 15 * log2(count + 1) - 10 * log2(1 + max(0, ?2 - last) / 86400) DESC
        LIMIT ?1
        """
        return visits(sql, args)
    }

    func search(_ query: String, limit: Int) -> [History.Visit] {
        let words = Self.split(query)
        var args: [Any] = [limit]
        let filters = words.map { word -> String in
            args.append(word)
            return "(instr(bare, ?\(args.count)) > 0 OR instr(ltitle, ?\(args.count)) > 0)"
        }
        let filter = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
        return visits("SELECT url, title, count FROM visits \(filter) ORDER BY last DESC LIMIT ?1", args)
    }

    private func visits(_ sql: String, _ args: [Any]) -> [History.Visit] {
        var found: [History.Visit] = []
        rows(sql, args) { found.append(History.Visit(url: $0.text(0), title: $0.text(1), count: $0.int(2))) }
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
        rows(sql, args) { _ in }
    }

    private func rows(_ sql: String, _ args: [Any], _ each: (Row) -> Void) {
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
            if step == SQLITE_ROW { each(Row(statement: statement)); continue }
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
