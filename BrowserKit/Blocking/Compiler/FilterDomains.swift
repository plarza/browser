import Foundation

/// The domains a filter names (`example.com`, `~shop.example.com`) as
/// WebKit's domain lists: each with `*` in front, for its subdomains too.
struct FilterDomains {
    private(set) var included: [String] = []
    private(set) var excluded: [String] = []

    /// Nil when an entry is something WebKit's domain lists can't say:
    /// entity matching (`google.*`) or a regex.
    init?(_ entries: some Sequence<some StringProtocol>) {
        for entry in entries {
            var domain = entry.trimmingCharacters(in: .whitespaces).lowercased()
            let isNegated = domain.hasPrefix("~")
            if isNegated { domain.removeFirst() }
            guard !domain.isEmpty, domain.allSatisfy(\.isASCII), !domain.hasSuffix(".*"), !domain.hasPrefix("/") else { return nil }
            if isNegated { excluded.append("*" + domain) } else { included.append("*" + domain) }
        }
    }

    /// WebKit takes domains to match or domains to leave out, never both,
    /// and a filter that names none has nothing to say.
    var isOneSided: Bool { included.isEmpty != excluded.isEmpty }

    /// The included domains as hosts, without the `*`, when each is a
    /// plain host name that can stand in a url-filter.
    var hosts: [String]? {
        let hosts = included.map { String($0.dropFirst()) }
        return hosts.allSatisfy(FilterDomains.isPlainHost) ? hosts : nil
    }

    static func isPlainHost(_ text: some StringProtocol) -> Bool {
        text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }
}
