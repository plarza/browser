import Foundation

/// An element-hiding filter (`##.ad`, `example.com##.sponsored`): a CSS
/// selector WebKit's style resolver hides, and where it hides it.
enum CosmeticFilter {
    /// Hidden on every page.
    case generic(String)
    /// Hidden on pages from these hosts and their subdomains.
    case sites([String], String)
    /// Hidden everywhere but on the domains the rule leaves out.
    case scoped(ContentRule)
    /// A cosmetic filter WebKit can't apply: an exception, a procedural
    /// selector, an entity (`google.*`).
    case skip

    /// Nil for a line that isn't a cosmetic filter.
    init?(_ line: String) {
        guard !CosmeticFilter.unsupportedMarkers.contains(where: line.contains) else { self = .skip; return }
        guard let marker = line.range(of: "##") else { return nil }
        let selector = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty, selector.allSatisfy(\.isASCII), !CosmeticFilter.procedural.contains(where: selector.contains) else {
            self = .skip
            return
        }
        let places = line[..<marker.lowerBound]
        guard !places.isEmpty else { self = .generic(selector); return }
        guard let domains = FilterDomains(places.split(separator: ",")), domains.isOneSided else { self = .skip; return }
        if domains.included.isEmpty {
            let trigger = ContentRule.Trigger(urlFilter: ContentRule.Trigger.everything, unlessDomain: domains.excluded)
            self = .scoped(.hide([selector], where: trigger))
        } else if let hosts = domains.hosts {
            self = .sites(hosts, selector)
        } else {
            self = .skip
        }
    }

    /// Exceptions, procedural, style-injecting and HTML filters.
    private static let unsupportedMarkers = ["#@#", "#?#", "#$#", "#@?#", "#@$#", "#%#", "##^", "#@%#"]

    /// Selector syntax only uBO's script understands.
    private static let procedural = [
        ":has-text", ":-abp-", ":matches-", ":xpath", ":upward", ":remove", ":style", ":watch-attr",
        ":min-text-length", ":others", ":if(", ":if-not", ":nth-ancestor", "+js(", ":matches-path",
        ":matches-css", ":matches-media", ":matches-attr", ":matches-prop", ":shadow",
    ]
}

/// The lists' cosmetic filters, gathered into as few rules as say them.
struct Hides {
    private var scoped: [ContentRule] = []
    private var generic: [String] = []
    /// Each site's selectors, and the sites in the order the lists name them.
    private var selectors: [String: [String]] = [:]
    private var sites: [String] = []

    mutating func add(_ filter: CosmeticFilter) {
        switch filter {
        case .generic(let selector):
            generic.append(selector)
        case .sites(let hosts, let selector):
            for host in hosts {
                if selectors[host] == nil { sites.append(host) }
                selectors[host, default: []].append(selector)
            }
        case .scoped(let rule):
            scoped.append(rule)
        case .skip:
            break
        }
    }

    var rules: [ContentRule] {
        var rules = scoped
        // Many selectors to a rule: one rule per selector would be tens of
        // thousands of rules all triggered by every URL.
        for start in stride(from: 0, to: generic.count, by: 500) {
            let trigger = ContentRule.Trigger(urlFilter: ContentRule.Trigger.everything)
            rules.append(.hide(generic[start ..< min(start + 500, generic.count)], where: trigger))
        }
        // A site's hides match the address of a page on it, not the site
        // showing: WebKit then passes them over in its URL matching for
        // every other page and every subresource, where tens of thousands
        // of `if-domain` rules are each checked on every request.
        for host in sites {
            let trigger = ContentRule.Trigger(urlFilter: ContentRule.Trigger.urlFilter(onHost: host), resourceType: [.document])
            rules.append(.hide(selectors[host] ?? [], where: trigger))
        }
        return rules
    }
}
