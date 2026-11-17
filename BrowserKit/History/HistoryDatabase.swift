import Foundation

/// history.db, and the one queue everything in it runs on, so a lookup
/// never holds up typing and changes land in the order they were made.
///
/// `visits` has a row for each page: its address, title, visit count, when
/// it was last visited, its frecency, and the copies of its text that
/// `Matching` describes. `picks` has what was typed before picking a page
/// from the list under the address field (see `Picks`).
actor HistoryDatabase {
    private let queue = DispatchSerialQueue(label: "Browser.History", qos: .userInitiated)
    private let file: URL
    /// Opened on the queue by whatever is asked of it first; nil if the
    /// file can't be opened, and then History remembers nothing.
    private(set) lazy var db = open()

    init(_ file: URL) {
        self.file = file
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// A change nobody waits for, made after every one asked for before it.
    nonisolated func write(_ change: @escaping @Sendable (isolated HistoryDatabase) -> Void) {
        queue.async { self.assumeIsolated(change) }
    }

    /// An answer for a caller that can't wait asynchronously: it stands
    /// still until the queue has got to it. The lookup itself still runs on
    /// the queue.
    nonisolated func read<Answer: Sendable>(_ lookup: (isolated HistoryDatabase) -> Answer) -> Answer {
        queue.sync { assumeIsolated(lookup) }
    }

    private func open() -> SQLite? {
        guard let db = SQLite(file) else { return nil }
        // Deleted rows are overwritten with zeros, not left in free pages.
        db.execute("""
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
        return db
    }

    // MARK: Writing

    /// A visit: a new page starts at the visit's weight; one already there
    /// has it added to what its score has faded to by today.
    func add(_ url: URL, weight: Double, today: Double) {
        let text = url.absoluteString
        let bare = History.bare(text).lowercased()
        let host = url.host?.lowercased() ?? ""
        db?.run("""
        INSERT INTO visits(url, bare, words, host, site, last, frecency)
        VALUES(?1, ?2, ?3, ?4, ?5, ?6 * 86400, ?6 + ln(?7) / ?8)
        ON CONFLICT(url) DO UPDATE SET count = count + 1, last = excluded.last,
            frecency = ?6 + ln(exp(?8 * (frecency - ?6)) + ?7) / ?8
        """, [text, bare, Matching.words(bare: bare, title: ""), host, Matching.site(host), today, weight, Frecency.λ])
    }

    /// Takes back the difference between a link's weight and a low one.
    func redirected(from url: String, today: Double) {
        db?.run("UPDATE visits SET frecency = ?2 + ln(max(exp(?3 * (frecency - ?2)) - ?4, 0.05)) / ?3 WHERE url = ?1",
                [url, today, Frecency.λ, History.Kind.link.weight - Frecency.low])
    }

    func setTitle(_ title: String, for url: String) {
        let lower = title.lowercased()
        db?.run("UPDATE visits SET title = ?2, ltitle = ?3, words = ?4 WHERE url = ?1 AND title != ?2",
                [url, title, lower, Matching.words(bare: History.bare(url).lowercased(), title: lower)])
    }

    func picked(_ url: String, after input: String, today: Double) {
        db?.run("""
        INSERT INTO picks(input, url, uses, day) VALUES(?1, ?2, 1, ?3)
        ON CONFLICT(input, url) DO UPDATE SET
            uses = min(\(Picks.most), uses * pow(\(Picks.fade), ?3 - day) * \(Picks.carried) + 1), day = ?3
        """, [input, url, today])
    }

    /// Picks that have faded away, about 90 days after their last use.
    func forgetFadedPicks(today: Double) {
        db?.run("DELETE FROM picks WHERE uses * pow(\(Picks.fade), ?1 - day) < \(Picks.forgotten)", [today])
    }

    /// A page goes, and what was typed to pick it.
    func remove(_ url: String) {
        db?.run("DELETE FROM visits WHERE url = ?1", [url])
        db?.run("DELETE FROM picks WHERE url = ?1", [url])
    }

    /// Everything goes, and the file shrinks to match.
    func clear() {
        db?.execute("DELETE FROM visits; DELETE FROM picks; VACUUM;")
    }

    // MARK: Reading

    /// Whether any visit is to `host`.
    func knows(host: String) -> Bool {
        db?.first("SELECT 1 FROM visits WHERE host = ?1 LIMIT 1", [host]) { _ in true } ?? false
    }

    func title(for url: String) -> String? {
        db?.first("SELECT title FROM visits WHERE url = ?1 AND title != ''", [url]) { $0.text(0) }
    }

    /// Every word must appear somewhere in the address or the title. Most
    /// recent first.
    func search(_ query: String, limit: Int) -> [History.Visit] {
        var values: [any SQLiteValue] = [limit]
        let filters = Matching.words(in: query).map { word in
            values.append(word)
            return "(instr(bare, ?\(values.count)) > 0 OR instr(ltitle, ?\(values.count)) > 0)"
        }
        let filter = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
        var found: [History.Visit] = []
        db?.rows("SELECT url, title, count FROM visits \(filter) ORDER BY last DESC LIMIT ?1", values) {
            found.append(History.Visit(url: $0.text(0), title: $0.text(1), count: $0.int(2)))
        }
        return found
    }
}
