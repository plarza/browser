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

    // MARK: Reading the block

    private static let opening = "==UserScript==", closing = "==/UserScript=="
    private static let runTimes = ["document-start", "document-body", "document-end", "document-idle"]

    /// Nil when the source has no metadata block.
    public static func parse(_ source: String) -> UserscriptMeta? {
        guard let start = source.range(of: opening),
              let end = source.range(of: closing, range: start.upperBound ..< source.endIndex)
        else { return nil }
        // The block is whole lines: from the start of the one that opens it
        // to the end of the one that closes it.
        let firstLine = source[..<start.lowerBound].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let lastLine = source[end.upperBound...].firstIndex(of: "\n") ?? source.endIndex
        var meta = UserscriptMeta()
        meta.block = String(source[firstLine ..< lastLine])
        for line in source[start.upperBound ..< end.lowerBound].split(whereSeparator: \.isNewline) {
            if let (key, value) = entry(in: line) { meta.set(key, value) }
        }
        if !runTimes.contains(meta.runAt) { meta.runAt = "document-end" }
        return meta
    }

    /// `// @key value`: the key and what follows it, or nil for any other line.
    private static func entry(in line: Substring) -> (key: String, value: String)? {
        var text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("//") else { return nil }
        text = text.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("@") else { return nil }
        let (key, value) = pair(text.dropFirst())
        // `@name:fr` and the like: localised, not ours to pick from.
        guard let key, !key.contains(":") else { return nil }
        return (key, value)
    }

    /// The word before the first space or tab, and the rest without the
    /// space around it.
    private static func pair(_ text: some StringProtocol) -> (first: String?, rest: String) {
        let parts = text.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        return (parts.first.map { String($0) }, parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
    }

    private mutating func set(_ key: String, _ value: String) {
        switch key.lowercased() {
        case "name": name = value
        case "namespace": namespace = value
        case "version": version = value
        case "description": description = value
        case "author": author = value
        case "homepage", "homepageurl", "website", "source": if homepage.isEmpty { homepage = value }
        case "icon", "iconurl", "defaulticon": if icon.isEmpty { icon = value }
        case "match": match.append(value)
        case "include": include.append(value)
        case "exclude": exclude.append(value)
        case "exclude-match": excludeMatch.append(value)
        case "grant": grant.append(value)
        case "connect": connect.append(value)
        case "require": require.append(value)
        case "resource":
            let (name, url) = UserscriptMeta.pair(value)
            if let name, !url.isEmpty { resources.append(Resource(name: name, url: url)) }
        case "run-at": runAt = value.lowercased()
        case "inject-into": injectInto = value.lowercased() == "content" ? "content" : "page"
        case "noframes": noframes = true
        case "unwrap": unwrap = true
        case "top-level-await": topLevelAwait = true
        case "updateurl": updateURL = value
        case "downloadurl", "installurl": downloadURL = value
        default: break
        }
    }

    // MARK: What it says

    /// The sites it runs on, for a line under its name: `youtube.com,
    /// github.com`, or "every site".
    public var sites: String {
        if match.isEmpty && include.isEmpty { return "every site" }
        var hosts: [String] = []
        for pattern in match + include {
            // A regular expression names no host worth showing.
            if pattern.hasPrefix("/") && pattern.count > 1 { continue }
            var host = pattern
            if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
            host = String(host.prefix { $0 != "/" })
            while host.hasPrefix("*.") || host.hasPrefix("*") || host.hasPrefix(".") { host.removeFirst() }
            if host.hasSuffix(".tld") { host = String(host.dropLast(4)) }
            if host.isEmpty || pattern == "<all_urls>" { host = "every site" }
            if !hosts.contains(host) { hosts.append(host) }
        }
        return hosts.isEmpty ? "some pages" : hosts.joined(separator: ", ")
    }

    /// Grants by what they do: `GM.xmlHttpRequest` and `GM_xmlhttpRequest`
    /// are one grant, as in Violentmonkey. An @unwrap script has none: it
    /// runs as the page's own code, with no GM APIs.
    var grants: Set<String> {
        if unwrap { return [] }
        return Set(grant.map { granted in
            let name = granted.lowercased()
            return name.hasPrefix("gm_") || name.hasPrefix("gm.") ? String(name.dropFirst(3)) : name
        })
    }

    /// Violentmonkey's comparison: dotted parts, numbers as numbers.
    public static func newer(_ a: String, than b: String) -> Bool {
        let ours = a.split(separator: "."), theirs = b.split(separator: ".")
        for index in 0 ..< max(ours.count, theirs.count) {
            let left = index < ours.count ? String(ours[index]) : "0"
            let right = index < theirs.count ? String(theirs[index]) : "0"
            if let m = Int(left), let n = Int(right) {
                if m != n { return m > n }
            } else if left != right {
                return left.compare(right, options: .numeric) == .orderedDescending
            }
        }
        return false
    }
}
