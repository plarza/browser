import Foundation

/// What the one field turns typed text into. Nothing typed leaves the
/// device until Return: no suggestions are fetched from anyone.
public enum Address {
    public enum Result: Equatable, Sendable {
        case go(URL)
        /// Words, with no search engine set.
        case needsSearchEngine
    }

    public static func resolve(_ text: String, searchTemplate: String) -> Result? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if let page = InternalPage(URL(string: typed.lowercased())) { return .go(page.url) }
        if let url = Bangs.resolve(typed) { return .go(url) }
        if let url = url(from: typed) { return .go(url) }
        guard let url = search(typed, template: searchTemplate) else { return .needsSearchEngine }
        return .go(url)
    }

    /// The text is an address, not words to search for or a bang: what
    /// counts as typed in History.
    public static func isAddress(_ text: String) -> Bool {
        url(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    /// An address, if the text looks like one. Plain `http` is turned into
    /// `https` later, by the navigation policy, so it can fall back.
    static func url(from typed: String) -> URL? {
        if let file = file(from: typed) { return file }
        if typed.contains(" ") { return nil }
        let lower = typed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: typed) }
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

    /// A file on this device: an absolute path (`/…`, `~/…`), as Finder's
    /// Copy as Pathname or a drag into Terminal gives it, or a `file://`
    /// address.
    static func file(from typed: String) -> URL? {
        var path = typed
        if path.count >= 2, let first = path.first, first == path.last, first == "'" || first == "\"" {
            path = String(path.dropFirst().dropLast())
        }
        if path.lowercased().hasPrefix("file://") {
            return URL(string: path).flatMap { $0.isFileURL && !$0.path.isEmpty ? $0 : nil }
        }
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        // Terminal escapes spaces and the like with a backslash.
        if !FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) {
            var plain = "", escaping = false
            for character in path {
                if character == "\\", !escaping { escaping = true } else { plain.append(character); escaping = false }
            }
            path = plain
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func search(_ words: String, template: String) -> URL? {
        guard template.contains("%s"),
              let encoded = words.addingPercentEncoding(withAllowedCharacters: queryAllowed)
        else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#/")
        return set
    }()
}
