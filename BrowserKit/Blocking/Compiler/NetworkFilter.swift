import Foundation

/// A network filter (`||ads.example.com^$third-party`, `@@||example.com^$document`)
/// as the WebKit rule that enforces it. What WebKit can't enforce as
/// written, such as a regex or a redirect, has no rule.
enum NetworkFilter {
    static func rule(for line: String) -> ContentRule? {
        var pattern = line
        let isException = pattern.hasPrefix("@@")
        if isException { pattern.removeFirst(2) }
        guard !isRegex(pattern) else { return nil }

        var options = Options()
        if let dollar = pattern.lastIndex(of: "$") {
            guard let given = Options(pattern[pattern.index(after: dollar)...]) else { return nil }
            options = given
            pattern = String(pattern[..<dollar])
        }
        guard pattern.allSatisfy(\.isASCII) else { return nil }

        if isException, options.isDocument {
            // A page the lists say not to block on: nothing on it is blocked.
            guard let host = plainHost(pattern) else { return nil }
            let page = "^[^:]+://([^/]*\\.)?" + ContentRule.Trigger.escape(host) + "[/:]"
            return .exception(ContentRule.Trigger(urlFilter: ContentRule.Trigger.everything, ifTopURL: [page]))
        }

        var trigger = ContentRule.Trigger(urlFilter: urlFilter(pattern))
        trigger.loadType = options.loadType.map { [$0] }
        trigger.ifDomain = options.ifDomain
        trigger.unlessDomain = options.unlessDomain
        guard let types = options.resourceTypes else { return nil }
        if !types.isEmpty { trigger.resourceType = types }
        // A rule that blocks every URL is a mistake on some list, not intent.
        if trigger.urlFilter == ContentRule.Trigger.everything, trigger.ifDomain == nil, trigger.resourceType == nil, !isException {
            return nil
        }
        return isException ? .exception(trigger) : .block(trigger)
    }

    /// A regex filter is /…/, perhaps with $options after it (and `$`
    /// inside it). A path filter like /ad-banner.js only starts with one.
    private static func isRegex(_ pattern: String) -> Bool {
        guard pattern.hasPrefix("/"), pattern.count > 2 else { return false }
        if pattern.hasSuffix("/") { return true }
        guard let options = pattern.range(of: "/$", options: .backwards) else { return false }
        return options.lowerBound > pattern.startIndex
    }

    /// The pattern part of a filter as a WebKit url-filter: a regex without
    /// alternation or counted repeats.
    private static func urlFilter(_ pattern: String) -> String {
        var rest = Substring(pattern)
        var filter = ""
        var startsAtHost = false
        if rest.hasPrefix("||") {
            rest = rest.dropFirst(2)
            filter = ContentRule.Trigger.anyHost
            startsAtHost = true
        } else if rest.hasPrefix("|") {
            rest = rest.dropFirst()
            filter = "^"
        }
        let endsAtEnd = rest.hasSuffix("|")
        if endsAtEnd { rest = rest.dropLast() }
        // A trailing separator after a host: WebKit's URLs always have a
        // `/` or `:` there, so it can be required. Anywhere else, at the
        // very end, it may also mean "the end", which WebKit can't say
        // without alternation; it is left off.
        let endsWithSeparator = rest.hasSuffix("^")
        if endsWithSeparator { rest = rest.dropLast() }
        while rest.hasPrefix("*") { rest = rest.dropFirst() }
        while rest.hasSuffix("*") { rest = rest.dropLast() }
        for character in rest {
            switch character {
            case "*": filter += ".*"
            case "^": filter += "[^a-zA-Z0-9_.%-]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$", "|": filter += "\\\(character)"
            default: filter.append(character)
            }
        }
        if endsWithSeparator, startsAtHost, !rest.contains("/") { filter += "[/:]" }
        if endsAtEnd { filter += "$" }
        return filter.isEmpty || filter == "^" ? ContentRule.Trigger.everything : filter
    }

    /// The host of a filter that is a host and nothing more (`||example.com^`).
    private static func plainHost(_ pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var host = pattern.dropFirst(2)
        if host.hasSuffix("^") { host.removeLast() }
        guard !host.isEmpty, FilterDomains.isPlainHost(host) else { return nil }
        return host.lowercased()
    }
}

/// What follows a network filter's `$`.
private struct Options {
    var loadType: ContentRule.LoadType?
    var ifDomain: [String]?
    var unlessDomain: [String]?
    var isDocument = false
    private var types: Set<ContentRule.ResourceType> = []
    private var notTypes: Set<ContentRule.ResourceType> = []

    init() {}

    /// Nil when one of them is an option whose meaning WebKit can't carry
    /// (`redirect`, `removeparam`, `csp`, `badfilter` and the like), or one
    /// Browser doesn't know: the rule is dropped rather than enforced as
    /// something it isn't.
    init?(_ text: Substring) {
        for option in text.split(separator: ",").map({ $0.lowercased() }) {
            let equals = option.firstIndex(of: "=")
            let name = equals.map { String(option[..<$0]) } ?? option
            switch name {
            case "third-party", "3p":
                loadType = .thirdParty
            case "~third-party", "first-party", "1p", "~3p":
                loadType = .firstParty
            case "domain", "from":
                guard let equals, let domains = FilterDomains(option[option.index(after: equals)...].split(separator: "|")),
                      domains.isOneSided
                else { return nil }
                if domains.included.isEmpty { unlessDomain = domains.excluded } else { ifDomain = domains.included }
            case "document", "doc":
                isDocument = true
            case "important", "match-case", "all", "_", "stealth":
                continue
            default:
                if let type = Options.typeNames[name] {
                    types.insert(type)
                } else if name.hasPrefix("~"), let type = Options.typeNames[String(name.dropFirst())] {
                    notTypes.insert(type)
                } else {
                    return nil
                }
            }
        }
    }

    /// The resource types the rule is for, in a fixed order; none for all
    /// of them. Nil when the filter rules out every type it could have had.
    var resourceTypes: [ContentRule.ResourceType]? {
        var types = types
        if isDocument { types.insert(.document) }
        if !notTypes.isEmpty {
            types = (types.isEmpty ? Options.allTypes : types).subtracting(notTypes)
            guard !types.isEmpty else { return nil }
        }
        return types.sorted { $0.rawValue < $1.rawValue }
    }

    /// The filter lists' names for WebKit's resource types.
    private static let typeNames: [String: ContentRule.ResourceType] = [
        "script": .script,
        "image": .image, "img": .image,
        "stylesheet": .styleSheet, "css": .styleSheet,
        "font": .font,
        "media": .media,
        "xmlhttprequest": .fetch, "xhr": .fetch,
        "websocket": .websocket,
        "ping": .ping, "beacon": .ping,
        "subdocument": .document, "frame": .document,
        "object": .other, "other": .other,
        "popup": .popup,
    ]

    /// What a filter that only rules types out (`$~image`) starts from.
    private static let allTypes: Set<ContentRule.ResourceType> = [
        .image, .styleSheet, .script, .font, .media, .fetch, .websocket, .ping, .other, .document,
    ]
}
