import Foundation

/// What the one field turns typed text into. Nothing typed leaves the Mac
/// until Return: no suggestions are fetched from anyone.
public enum Address {
    public enum Result: Equatable {
        case go(URL)
        /// Words, with no search engine set.
        case needsSearchEngine
    }

    public static func resolve(_ text: String, searchTemplate: String) -> Result? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if let url = URL(string: typed.lowercased()), HistoryPage.isHistory(url) { return .go(HistoryPage.address) }
        if let url = Bangs.resolve(typed) { return .go(url) }
        if let url = url(from: typed) { return .go(url) }
        guard let url = search(typed, template: searchTemplate) else { return .needsSearchEngine }
        return .go(url)
    }

    /// An address, if the text looks like one. Plain `http` is turned into
    /// `https` later, by the navigation policy, so it can fall back.
    static func url(from typed: String) -> URL? {
        if typed.contains(" ") { return nil }
        let lower = typed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: typed)
        }
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") { return nil }
        // localhost, a dotted name, an IPv4 address or a bracketed IPv6 one,
        // optionally with a port and path.
        guard let candidate = URL(string: "https://" + typed), let host = candidate.host, !host.isEmpty else { return nil }
        if host == "localhost" || host.hasPrefix("[") || host.contains(":") { return candidate }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { return nil }
        return candidate
    }

    static func search(_ words: String, template: String) -> URL? {
        guard template.contains("%s"),
              let encoded = words.addingPercentEncoding(withAllowedCharacters: queryAllowed)
        else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#/")
        return set
    }()
}
