import Foundation

/// A userscript's `// ==UserScript==` block, read the way Violentmonkey
/// reads it.
public struct UserscriptMeta: Equatable, Sendable {
    public var name = ""
    public var namespace = ""
    public var version = ""
    public var description = ""
    public var author = ""
    public var homepage = ""
    public var icon = ""
    public var match: [String] = []
    public var include: [String] = []
    public var exclude: [String] = []
    public var excludeMatch: [String] = []
    public var grant: [String] = []
    public var connect: [String] = []
    public var require: [String] = []
    /// `@resource name url`, in order.
    public var resources: [Resource] = []
    /// document-start, document-body, document-end (the default) or document-idle.
    public var runAt = "document-end"
    /// page (also auto, the default) or content: Browser's own isolated world.
    public var injectInto = "page"
    public var noframes = false
    public var unwrap = false
    public var topLevelAwait = false
    public var updateURL = ""
    public var downloadURL = ""
    /// The block as written, for `GM_info.scriptMetaStr`.
    public var block = ""

    public struct Resource: Equatable, Sendable {
        public let name: String
        public let url: String
    }

    public init() {}

    /// Nil when the source has no metadata block.
    public static func parse(_ source: String) -> UserscriptMeta? {
        guard let start = source.range(of: "==UserScript=="),
              let end = source.range(of: "==/UserScript==", range: start.upperBound ..< source.endIndex)
        else { return nil }
        let lineStart = source[..<start.lowerBound].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let lineEnd = source[end.upperBound...].firstIndex(of: "\n") ?? source.endIndex
        var meta = UserscriptMeta()
        meta.block = String(source[lineStart ..< lineEnd])
        for line in source[start.upperBound ..< end.lowerBound].split(whereSeparator: \.isNewline) {
            var text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("//") else { continue }
            text = text.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("@") else { continue }
            let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let rawKey = parts.first else { continue }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            // `@name:fr` and the like: localised, not ours to pick from.
            let key = String(rawKey)
            if key.contains(":") { continue }
            switch key.lowercased() {
            case "name": meta.name = value
            case "namespace": meta.namespace = value
            case "version": meta.version = value
            case "description": meta.description = value
            case "author": meta.author = value
            case "homepage", "homepageurl", "website", "source": if meta.homepage.isEmpty { meta.homepage = value }
            case "icon", "iconurl", "defaulticon": if meta.icon.isEmpty { meta.icon = value }
            case "match": meta.match.append(value)
            case "include": meta.include.append(value)
            case "exclude": meta.exclude.append(value)
            case "exclude-match": meta.excludeMatch.append(value)
            case "grant": meta.grant.append(value)
            case "connect": meta.connect.append(value)
            case "require": meta.require.append(value)
            case "resource":
                let pair = value.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
                if pair.count == 2 {
                    meta.resources.append(Resource(name: String(pair[0]), url: pair[1].trimmingCharacters(in: .whitespaces)))
                }
            case "run-at": meta.runAt = value.lowercased()
            case "inject-into": meta.injectInto = value.lowercased() == "content" ? "content" : "page"
            case "noframes": meta.noframes = true
            case "unwrap": meta.unwrap = true
            case "top-level-await": meta.topLevelAwait = true
            case "updateurl": meta.updateURL = value
            case "downloadurl", "installurl": meta.downloadURL = value
            default: break
            }
        }
        if !["document-start", "document-body", "document-end", "document-idle"].contains(meta.runAt) {
            meta.runAt = "document-end"
        }
        return meta
    }

    /// The sites it runs on, for a line under its name: `youtube.com,
    /// github.com`, or "every site".
    public var sites: String {
        var hosts: [String] = []
        for pattern in match + include {
            var host = pattern
            if pattern.hasPrefix("/") && pattern.count > 1 { continue }
            if let r = host.range(of: "://") { host = String(host[r.upperBound...]) }
            host = String(host.prefix { $0 != "/" })
            while host.hasPrefix("*.") || host.hasPrefix("*") || host.hasPrefix(".") { host.removeFirst() }
            if host.hasSuffix(".tld") { host = String(host.dropLast(4)) }
            if host.isEmpty || pattern == "<all_urls>" { host = "every site" }
            if !hosts.contains(host) { hosts.append(host) }
        }
        if match.isEmpty && include.isEmpty { return "every site" }
        return hosts.isEmpty ? "some pages" : hosts.joined(separator: ", ")
    }

    /// Grants by what they do: `GM.xmlHttpRequest` and `GM_xmlhttpRequest`
    /// are one grant, as in Violentmonkey.
    var grants: Set<String> {
        Set(grant.map { g in
            var name = g.lowercased()
            if name.hasPrefix("gm_") || name.hasPrefix("gm.") { name.removeFirst(3) }
            if name == "getresourceurl" { return "getresourceurl" }
            return name
        })
    }

    /// Violentmonkey's comparison: dotted parts, numbers as numbers.
    public static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: "."), y = b.split(separator: ".")
        for i in 0 ..< max(x.count, y.count) {
            let p = i < x.count ? String(x[i]) : "0", q = i < y.count ? String(y[i]) : "0"
            if let m = Int(p), let n = Int(q) {
                if m != n { return m > n }
            } else if p != q {
                return p.compare(q, options: .numeric) == .orderedDescending
            }
        }
        return false
    }
}

/// Where a script runs, as regular expressions both the app and the page
/// can test: the app to decide which scripts a page gets, the page to check
/// its own address again (a web view keeps its scripts across links).
struct UserscriptRules: Sendable {
    /// Each a `[source, flags]` pair, as a JavaScript RegExp takes them.
    var include: [[String]] = []
    var exclude: [[String]] = []
    /// No @match and no @include: every page, as in Violentmonkey.
    var everywhere = false
    private var compiledInclude: [NSRegularExpression?] = []
    private var compiledExclude: [NSRegularExpression?] = []

    init(_ meta: UserscriptMeta) {
        everywhere = meta.match.isEmpty && meta.include.isEmpty
        include = meta.match.compactMap(UserscriptRules.fromMatch) + meta.include.compactMap(UserscriptRules.fromInclude)
        exclude = meta.excludeMatch.compactMap(UserscriptRules.fromMatch) + meta.exclude.compactMap(UserscriptRules.fromInclude)
        compiledInclude = include.map(UserscriptRules.compile)
        compiledExclude = exclude.map(UserscriptRules.compile)
    }

    /// A rule NSRegularExpression can't read counts as matching: the page,
    /// with JavaScript's own RegExp, has the last word.
    func matches(_ url: String) -> Bool {
        let test = { (re: NSRegularExpression?) -> Bool in
            guard let re else { return true }
            return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
        guard everywhere || compiledInclude.contains(where: test) else { return false }
        return !compiledExclude.contains { $0 != nil && test($0) }
    }

    private static func compile(_ rule: [String]) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: rule[0], options: rule[1].contains("i") ? [.caseInsensitive] : [])
    }

    private static func escape(_ s: Substring) -> String {
        var out = ""
        for c in s {
            if "\\^$.|?+()[]{}/".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// `.tld`: any public suffix, roughly (`com`, `co.uk`).
    private static let tld = "\\.(?:[a-z0-9-]+\\.)?[a-z0-9-]+"

    /// A match pattern: `*://*.example.com/path*`, or `<all_urls>`.
    static func fromMatch(_ pattern: String) -> [String]? {
        if pattern == "<all_urls>" { return ["^(?:https?|file)://", ""] }
        guard let sep = pattern.range(of: "://") else { return nil }
        let scheme = pattern[..<sep.lowerBound]
        let rest = pattern[sep.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var host = rest[..<slash]
        let path = slash < rest.endIndex ? rest[slash...] : "/*"
        let schemeRe = scheme == "*" ? "https?" : escape(scheme)
        var hostRe: String
        var tld = false
        if host.hasSuffix(".tld") { tld = true; host = host.dropLast(4) }
        if host == "*" {
            hostRe = "[^/]*"
        } else {
            var port = ""
            if let colon = host.lastIndex(of: ":"), !host[host.index(after: colon)...].isEmpty {
                port = host[host.index(after: colon)...] == "*" ? "(?::\\d+)?" : ":" + escape(host[host.index(after: colon)...])
                host = host[..<colon]
            } else {
                port = "(?::\\d+)?"
            }
            if host.hasPrefix("*.") {
                hostRe = "(?:[^/:@]+\\.)?" + escape(host.dropFirst(2))
            } else {
                hostRe = escape(host)
            }
            if tld { hostRe += UserscriptRules.tld }
            hostRe += port
        }
        let pathRe = path.split(separator: "*", omittingEmptySubsequences: false).map(escape).joined(separator: ".*")
        return ["^" + schemeRe + "://" + (scheme == "file" ? "" : "(?:[^/@]*@)?") + hostRe + pathRe + "$", ""]
    }

    /// An @include: a glob with `*`, or a `/regular expression/`.
    static func fromInclude(_ pattern: String) -> [String]? {
        if pattern.count > 2, pattern.hasPrefix("/"), let close = pattern.lastIndex(of: "/"), close != pattern.startIndex {
            let flags = String(pattern[pattern.index(after: close)...])
            if flags.allSatisfy({ "gimsuy".contains($0) }) {
                return [String(pattern[pattern.index(after: pattern.startIndex) ..< close]), flags.contains("i") ? "i" : ""]
            }
        }
        if pattern == "*" { return ["^", ""] }
        var re = ""
        var rest = Substring(pattern)
        while !rest.isEmpty {
            if rest.hasPrefix(".tld/") || rest == ".tld" || rest.hasPrefix(".tld:") {
                re += tld
                rest = rest.dropFirst(4)
            } else if rest.first == "*" {
                re += ".*"
                rest = rest.dropFirst()
            } else {
                re += escape(rest.prefix(1))
                rest = rest.dropFirst()
            }
        }
        return ["^" + re + "$", "i"]
    }
}
