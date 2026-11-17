import Foundation

/// Where a script runs, as regular expressions both the app and the page
/// can test: the app to decide which scripts a page gets, the page to check
/// its own address again (a web view keeps its scripts across links).
struct UserscriptRules: Sendable {
    /// One rule, as a JavaScript RegExp takes it.
    struct Rule: Sendable {
        let source: String
        let flags: String
        /// Nil when NSRegularExpression can't read what JavaScript can.
        private let expression: NSRegularExpression?

        init(_ source: String, flags: String = "") {
            self.source = source
            self.flags = flags
            expression = try? NSRegularExpression(pattern: source, options: flags.contains("i") ? [.caseInsensitive] : [])
        }

        /// The `[source, flags]` pair the page makes its RegExp from.
        var pair: [String] { [source, flags] }

        /// Nil when the app can't tell.
        func matches(_ address: String) -> Bool? {
            guard let expression else { return nil }
            return expression.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil
        }
    }

    /// @match and @include.
    let include: [Rule]
    /// @exclude-match and @exclude.
    let exclude: [Rule]
    /// No @match and no @include: every page, as in Violentmonkey.
    let everywhere: Bool

    init(_ meta: UserscriptMeta) {
        everywhere = meta.match.isEmpty && meta.include.isEmpty
        include = meta.match.compactMap(Rule.init(match:)) + meta.include.compactMap(Rule.init(include:))
        exclude = meta.excludeMatch.compactMap(Rule.init(match:)) + meta.exclude.compactMap(Rule.init(include:))
    }

    /// A rule NSRegularExpression can't read counts as including, and
    /// never as excluding: the page, with JavaScript's own RegExp, has the
    /// last word.
    func matches(_ address: String) -> Bool {
        guard everywhere || include.contains(where: { $0.matches(address) ?? true }) else { return false }
        return !exclude.contains { $0.matches(address) == true }
    }
}

extension UserscriptRules.Rule {
    /// `.tld`: any public suffix, roughly (`com`, `co.uk`).
    private static let anySuffix = "\\.(?:[a-z0-9-]+\\.)?[a-z0-9-]+"

    /// A match pattern: `*://*.example.com/path*`, or `<all_urls>`. Nil
    /// when it has no scheme.
    init?(match pattern: String) {
        if pattern == "<all_urls>" {
            self.init("^(?:https?|file)://")
            return
        }
        guard let separator = pattern.range(of: "://") else { return nil }
        let scheme = pattern[..<separator.lowerBound]
        let rest = pattern[separator.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let path = slash < rest.endIndex ? rest[slash...] : "/*"
        let credentials = scheme == "file" ? "" : "(?:[^/@]*@)?"
        self.init("^" + (scheme == "*" ? "https?" : Self.escape(scheme)) + "://" + credentials
            + Self.host(rest[..<slash]) + Self.glob(path, any: ".*") + "$")
    }

    /// The host of a match pattern, with its port: `*`, `*.example.com`,
    /// `example.tld`, `localhost:8080`, `localhost:*`. A host that names no
    /// port matches any.
    private static func host(_ pattern: Substring) -> String {
        var host = pattern
        let anyTLD = host.hasSuffix(".tld")
        if anyTLD { host = host.dropLast(4) }
        if host == "*" { return "[^/]*" }
        var port = "(?::\\d+)?"
        if let colon = host.lastIndex(of: ":"), case let named = host[host.index(after: colon)...], !named.isEmpty {
            if named != "*" { port = ":" + escape(named) }
            host = host[..<colon]
        }
        let name = host.hasPrefix("*.") ? "(?:[^/:@]+\\.)?" + escape(host.dropFirst(2)) : escape(host)
        return name + (anyTLD ? anySuffix : "") + port
    }

    /// An @include or @exclude: a glob with `*` (and `.tld`), or a
    /// `/regular expression/`.
    init?(include pattern: String) {
        if pattern.count > 2, pattern.hasPrefix("/"), let close = pattern.lastIndex(of: "/"), close != pattern.startIndex {
            let flags = pattern[pattern.index(after: close)...]
            if flags.allSatisfy({ "gimsuy".contains($0) }) {
                self.init(String(pattern[pattern.index(after: pattern.startIndex) ..< close]), flags: flags.contains("i") ? "i" : "")
                return
            }
        }
        if pattern == "*" {
            self.init("^")
            return
        }
        var expression = ""
        var rest = Substring(pattern)
        while let character = rest.first {
            if rest.hasPrefix(".tld/") || rest == ".tld" || rest.hasPrefix(".tld:") {
                expression += Self.anySuffix
                rest = rest.dropFirst(4)
            } else {
                expression += character == "*" ? ".*" : Self.escape(rest.prefix(1))
                rest = rest.dropFirst()
            }
        }
        self.init("^" + expression + "$", flags: "i")
    }

    /// `text` with each `*` standing for `any`, and the rest taken literally.
    private static func glob(_ text: Substring, any: String) -> String {
        text.split(separator: "*", omittingEmptySubsequences: false).map(escape).joined(separator: any)
    }

    /// `text` as a regular expression that matches exactly it.
    private static func escape(_ text: Substring) -> String {
        var escaped = ""
        for character in text {
            if "\\^$.|?+()[]{}/".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
