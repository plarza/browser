import Foundation

/// The address field's completion: what to fill in, and the pages for the
/// list under the field.
extension HistoryDatabase {
    func complete(_ typed: String, limit: Int, today: Double) -> History.Completion {
        History.Completion(fill: fill(for: typed, today: today), pages: pages(for: typed, limit: limit, today: today))
    }

    /// As Chrome and Safari do, a site you've been to whose name starts
    /// with what you typed (`git` → `github.com`), the one with the highest
    /// frecency; once you type a `/`, a whole address that starts with it.
    private func fill(for typed: String, today: Double) -> String? {
        let typed = typed.lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        // Everything that starts with `typed`, as a range the index can use.
        let end = Matching.end(of: typed)
        if typed.contains("/") {
            return db?.first("SELECT url FROM visits WHERE bare > ?1 AND bare < ?2 ORDER BY frecency DESC LIMIT 1", [typed, end]) {
                History.bare($0.text(0))
            }
        }
        // A site's score is the sum of its pages' scores today.
        return db?.first("""
        SELECT site FROM visits WHERE site > ?1 AND site < ?2
        GROUP BY site ORDER BY sum(exp(?3 * (frecency - ?4))) DESC, length(site) LIMIT 1
        """, [typed, end, Frecency.λ, today]) { $0.text(0) }
    }

    /// Pages picked before after typing this, or more, come first. The rest
    /// rank by how early in their address or title the words match (the
    /// start of the address best, then the start of any word, then
    /// anywhere), plus their frecency.
    private func pages(for typed: String, limit: Int, today: Double) -> [History.Visit] {
        let words = Matching.words(in: typed)
        guard !words.isEmpty else { return [] }
        // Picked before: at most half the list, so the rest still shows.
        let picks = picked(after: words.joined(separator: " "), limit: (limit + 1) / 2, today: today)
        return picks + matching(words, limit: limit - picks.count, besides: Set(picks.map(\.url)))
    }

    /// Pages picked after typing `typed` or something that starts with it,
    /// the most used first. A pick for exactly this counts double.
    private func picked(after typed: String, limit: Int, today: Double) -> [History.Visit] {
        var found: [History.Visit] = []
        db?.rows("""
        SELECT v.url, v.title, v.count, max(p.uses * pow(\(Picks.fade), ?2 - p.day) * (1 + (p.input = ?1))) AS rank
        FROM picks p JOIN visits v ON v.url = p.url
        WHERE p.input >= ?1 AND p.input < ?3
        GROUP BY v.url HAVING rank >= \(Picks.forgotten) ORDER BY rank DESC, v.frecency DESC LIMIT ?4
        """, [typed, today, Matching.end(of: typed), limit]) {
            found.append(History.Visit(url: $0.text(0), title: $0.text(1), count: $0.int(2)))
        }
        return found
    }

    /// The best `limit` pages with every word somewhere in their address or
    /// title, leaving out `besides`.
    private func matching(_ words: [String], limit: Int, besides: Set<String>) -> [History.Visit] {
        guard limit > 0 else { return [] }
        var values: [any SQLiteValue] = []
        var filters: [String] = []
        var points: [String] = []
        for word in words {
            let whole = values.count + 1, start = whole + 1
            values.append(word)
            values.append(Matching.start(of: word))
            filters.append("(instr(bare, ?\(whole)) > 0 OR instr(ltitle, ?\(whole)) > 0)")
            points.append("CASE WHEN substr(bare, 1, length(?\(whole))) = ?\(whole) THEN 100 WHEN instr(words, ?\(start)) > 0 THEN 50 ELSE 10 END")
        }
        // Read in frecency order: a page's rank is its match points plus
        // its frecency's, so once the best match points a page could have
        // can't lift it past the last of the best so far, no page after it
        // can do better, and the scan stops.
        let most = 100.0 * Double(words.count)
        var best: [(rank: Double, visit: History.Visit)] = []
        db?.scan("""
        SELECT url, title, count, frecency, \(points.joined(separator: " + ")) FROM visits
        WHERE \(filters.joined(separator: " AND ")) ORDER BY frecency DESC
        """, values) { row in
            let frecency = Frecency.points * row.double(3)
            if best.count == limit, frecency + most <= best[limit - 1].rank { return false }
            let url = row.text(0)
            guard !besides.contains(url) else { return true }
            let rank = frecency + row.double(4)
            guard best.count < limit || rank > best[limit - 1].rank else { return true }
            let visit = History.Visit(url: url, title: row.text(1), count: row.int(2))
            best.insert((rank, visit), at: best.firstIndex { $0.rank < rank } ?? best.count)
            if best.count > limit { best.removeLast() }
            return true
        }
        return best.map(\.visit)
    }
}
