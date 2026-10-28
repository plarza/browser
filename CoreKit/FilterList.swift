import Foundation

/// Adblock Plus / uBlock Origin filter syntax, turned into WebKit content
/// rules. What WebKit can enforce inside its networking and its style
/// resolver is kept; what needs a script running in the page (scriptlets,
/// procedural cosmetics, redirects) is dropped, since a script in the page
/// is something the page can detect.
public enum FilterList {
    public struct Output {
        public var blocks: [[String: Any]] = []
        public var hides: [[String: Any]] = []
        public var exceptions: [[String: Any]] = []
        public var skipped = 0

        /// In the order WebKit needs: an `ignore-previous-rules` only undoes
        /// what came before it.
        public var rules: [[String: Any]] { blocks + hides + exceptions }

        /// The rules as several lists: WebKit takes at most 150,000 rules in
        /// one. An exception only undoes rules in its own list, so every list
        /// ends with all of them.
        public func lists(limit: Int = 150_000) -> [[[String: Any]]] {
            let room = max(1000, limit - exceptions.count)
            var lists: [[[String: Any]]] = stride(from: 0, to: blocks.count, by: room).map {
                Array(blocks[$0 ..< min($0 + room, blocks.count)]) + exceptions
            }
            for start in stride(from: 0, to: hides.count, by: room) {
                lists.append(Array(hides[start ..< min(start + room, hides.count)]) + exceptions)
            }
            return lists
        }
    }

    public static func compile(_ texts: [String]) -> Output {
        var out = Output()
        var genericHides: [String] = []
        var seen = Set<String>()
        var seenRules = Set<Data>()
        for text in texts {
            text.enumerateLines { raw, _ in
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), seen.insert(line).inserted else { return }
                if let cosmetic = cosmetic(line) {
                    switch cosmetic {
                    case .generic(let selector): genericHides.append(selector)
                    case .scoped(let rule): out.hides.append(rule)
                    case .skip: out.skipped += 1
                    }
                    return
                }
                if let (rule, isException) = network(line) {
                    // The lists overlap: the same rule, written differently,
                    // comes out the same here.
                    guard let key = try? JSONSerialization.data(withJSONObject: rule, options: .sortedKeys),
                          seenRules.insert(key).inserted else { return }
                    if isException { out.exceptions.append(rule) } else { out.blocks.append(rule) }
                } else {
                    out.skipped += 1
                }
            }
        }
        // Many selectors to a rule: one rule per selector would be tens of
        // thousands of rules all triggered by every URL.
        for chunk in stride(from: 0, to: genericHides.count, by: 500) {
            let selectors = genericHides[chunk ..< min(chunk + 500, genericHides.count)]
            out.hides.append([
                "trigger": ["url-filter": ".*"],
                "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")],
            ])
        }
        return out
    }

    // MARK: Cosmetic

    enum Cosmetic {
        case generic(String)
        case scoped([String: Any])
        case skip
    }

    /// Selector syntax only uBO's script understands.
    static let procedural = [
        ":has-text", ":-abp-", ":matches-", ":xpath", ":upward", ":remove", ":style", ":watch-attr",
        ":min-text-length", ":others", ":if(", ":if-not", ":nth-ancestor", "+js(", ":matches-path",
        ":matches-css", ":matches-media", ":matches-attr", ":matches-prop", ":shadow",
    ]

    static func cosmetic(_ line: String) -> Cosmetic? {
        for marker in ["#@#", "#?#", "#$#", "#@?#", "#@$#", "#%#", "##^", "#@%#"] where line.contains(marker) {
            return .skip
        }
        guard let range = line.range(of: "##") else { return nil }
        let domains = String(line[..<range.lowerBound])
        let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty, selector.allSatisfy(\.isASCII),
              !procedural.contains(where: selector.contains)
        else { return .skip }
        if domains.isEmpty { return .generic(selector) }
        guard let (include, exclude) = domainLists(domains.split(separator: ",").map(String.init)),
              include.isEmpty != exclude.isEmpty
        else { return .skip }
        var trigger: [String: Any] = ["url-filter": ".*"]
        if !include.isEmpty { trigger["if-domain"] = include } else { trigger["unless-domain"] = exclude }
        return .scoped(["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]])
    }

    // MARK: Network

    static let typeNames: [String: [String]] = [
        "script": ["script"],
        "image": ["image"], "img": ["image"],
        "stylesheet": ["style-sheet"], "css": ["style-sheet"],
        "font": ["font"],
        "media": ["media"],
        "xmlhttprequest": ["fetch"], "xhr": ["fetch"],
        "websocket": ["websocket"],
        "ping": ["ping"], "beacon": ["ping"],
        "subdocument": ["document"], "frame": ["document"],
        "object": ["other"], "other": ["other"],
        "popup": ["popup"],
    ]

    static let allTypes = ["image", "style-sheet", "script", "font", "media", "fetch", "websocket", "ping", "other", "document"]

    /// Options whose meaning WebKit can't carry; a rule with one is dropped
    /// rather than enforced as something it isn't.
    static let unsupported: Set<String> = [
        "redirect", "redirect-rule", "removeparam", "queryprune", "csp", "header", "replace",
        "rewrite", "generichide", "ghide", "elemhide", "ehide", "specifichide", "shide",
        "badfilter", "permissions", "denyallow", "method", "strict1p", "strict3p", "cname",
        "inline-script", "inline-font", "empty", "mp4", "uritransform", "urlskip", "ipaddress",
        "to", "genericblock", "webrtc", "rewrite", "reason",
    ]

    static func network(_ line: String) -> ([String: Any], Bool)? {
        var text = line
        let isException = text.hasPrefix("@@")
        if isException { text.removeFirst(2) }

        // A regex filter is /…/ and may itself contain `$`.
        if text.hasPrefix("/") { return nil }

        var options: [String] = []
        if let dollar = text.lastIndex(of: "$") {
            options = text[text.index(after: dollar)...].split(separator: ",").map { String($0).lowercased() }
            text = String(text[..<dollar])
        }
        guard text.allSatisfy(\.isASCII) else { return nil }

        var trigger: [String: Any] = [:]
        var types: Set<String> = []
        var notTypes: Set<String> = []
        var isDocument = false
        for option in options {
            let (name, value): (String, String?) = {
                guard let eq = option.firstIndex(of: "=") else { return (option, nil) }
                return (String(option[..<eq]), String(option[option.index(after: eq)...]))
            }()
            switch name {
            case "third-party", "3p": trigger["load-type"] = ["third-party"]
            case "~third-party", "first-party", "1p", "~3p": trigger["load-type"] = ["first-party"]
            case "domain", "from":
                guard let value, let (include, exclude) = domainLists(value.split(separator: "|").map(String.init)),
                      include.isEmpty != exclude.isEmpty
                else { return nil }
                if !include.isEmpty { trigger["if-domain"] = include } else { trigger["unless-domain"] = exclude }
            case "document", "doc":
                isDocument = true
            case "important", "match-case", "all", "_", "stealth":
                continue
            default:
                if let mapped = typeNames[name] { types.formUnion(mapped); continue }
                if name.hasPrefix("~"), let mapped = typeNames[String(name.dropFirst())] {
                    notTypes.formUnion(mapped)
                    continue
                }
                if unsupported.contains(name) { return nil }
                return nil
            }
        }

        if isException && isDocument {
            // A page the lists say not to block on: nothing on it is blocked.
            guard let host = plainHost(text) else { return nil }
            return ([
                "trigger": ["url-filter": ".*", "if-top-url": ["^[^:]+://([^/]*\\.)?" + escape(host) + "[/:]"]],
                "action": ["type": "ignore-previous-rules"],
            ], true)
        }
        if isDocument && !isException { types.insert("document") }

        if !notTypes.isEmpty {
            types = Set(types.isEmpty ? allTypes : Array(types)).subtracting(notTypes)
            guard !types.isEmpty else { return nil }
        }
        if !types.isEmpty { trigger["resource-type"] = types.sorted() }

        guard let filter = urlFilter(text) else { return nil }
        trigger["url-filter"] = filter
        // A rule that blocks every URL is a mistake on some list, not intent.
        if filter == ".*", trigger["if-domain"] == nil, trigger["resource-type"] == nil, !isException { return nil }
        return (["trigger": trigger, "action": ["type": isException ? "ignore-previous-rules" : "block"]], isException)
    }

    /// The pattern part of a filter as a WebKit url-filter: a regex without
    /// alternation or counted repeats.
    static func urlFilter(_ pattern: String) -> String? {
        var p = Substring(pattern)
        var out = ""
        if p.hasPrefix("||") {
            p = p.dropFirst(2)
            out = "^[^:]+://+([^:/]+\\.)?"
        } else if p.hasPrefix("|") {
            p = p.dropFirst()
            out = "^"
        }
        var anchoredEnd = false
        if p.hasSuffix("|") { p = p.dropLast(); anchoredEnd = true }
        // A trailing separator after a host: WebKit's URLs always have a
        // `/` or `:` there, so it can be required. Anywhere else, at the
        // very end, it may also mean "the end", which WebKit can't say
        // without alternation; it is left off.
        let trailingSeparator = p.hasSuffix("^")
        if trailingSeparator { p = p.dropLast() }
        while p.hasPrefix("*") { p = p.dropFirst() }
        while p.hasSuffix("*") { p = p.dropLast() }
        for ch in p {
            switch ch {
            case "*": out += ".*"
            case "^": out += "[^a-zA-Z0-9_.%-]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$", "|": out += "\\\(ch)"
            default: out.append(ch)
            }
        }
        if trailingSeparator, out.hasPrefix("^[^:]+://"), !p.contains("/") { out += "[/:]" }
        if anchoredEnd { out += "$" }
        if out.isEmpty || out == "^" { return ".*" }
        return out
    }

    static func domainLists(_ entries: [String]) -> ([String], [String])? {
        var include: [String] = []
        var exclude: [String] = []
        for raw in entries {
            var d = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = d.hasPrefix("~")
            if negated { d.removeFirst() }
            // Entity matching (`google.*`) and regex domains aren't
            // something WebKit's domain lists can say.
            guard !d.isEmpty, d.allSatisfy(\.isASCII), !d.hasSuffix(".*"), !d.hasPrefix("/") else { return nil }
            if negated { exclude.append("*" + d) } else { include.append("*" + d) }
        }
        return (include, exclude)
    }

    static func plainHost(_ pattern: String) -> String? {
        var p = pattern
        guard p.hasPrefix("||") else { return nil }
        p.removeFirst(2)
        if p.hasSuffix("^") { p.removeLast() }
        guard !p.isEmpty, p.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return p.lowercased()
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: "\\.")
    }
}
