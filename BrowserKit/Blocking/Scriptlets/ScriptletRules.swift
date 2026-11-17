import Foundation

/// The filter lists' scriptlets (`example.com##+js(json-prune, adPlacements)`):
/// what a list asks to run in a site's pages before any of the site's own
/// scripts, where blocking a request can't help (YouTube's ads come from the
/// same servers as its videos).
///
/// Kept in scriptlets.json between launches, so a page's scriptlets are
/// known before the day's lists have been fetched.
public struct ScriptletRules: Codable, Sendable {
    /// Each call as JSON: `["json-prune","adPlacements"]`.
    private(set) var calls: [String] = []
    /// A host, an entity (`google.*`) or `*`, to the calls it runs; `~i`
    /// for an exception to call `i`, `Int.min` for "none here".
    private(set) var sites: [String: [Int]] = [:]

    public var count: Int { calls.count }

    /// The calls for a page on `host`, as JSON.
    func calls(for host: String) -> [String] {
        var run = Set<Int>(), off = Set<Int>()
        for key in ScriptletRules.keys(for: host) {
            for call in sites[key] ?? [] {
                if call >= 0 { run.insert(call) } else { off.insert(call == Int.min ? call : ~call) }
            }
        }
        if off.contains(Int.min) { return [] }
        return run.subtracting(off).sorted().map { calls[$0] }
    }

    /// Every name a rule for `host` can be filed under.
    private static func keys(for host: String) -> [String] {
        let host = host.lowercased()
        let labels = host.split(separator: ".")
        var keys = labels.indices.map { labels[$0...].joined(separator: ".") }
        // `google.*`: the site's name with any public suffix after it.
        if let suffix = Site.suffix(of: host), host.count > suffix.count {
            let named = host.dropLast(suffix.count + 1).split(separator: ".")
            keys += named.indices.map { named[$0...].joined(separator: ".") + ".*" }
        }
        return keys + ["*"]
    }
}

extension ScriptletRules {
    /// Gathers the lists' scriptlet filters into rules, each call kept once
    /// however many filters make it.
    struct Builder {
        private(set) var rules = ScriptletRules()
        private var indices: [String: Int] = [:]

        mutating func add(_ filter: ScriptletFilter) {
            switch filter {
            case .run(let call, let hosts, let except):
                let call = index(of: call)
                for host in hosts.isEmpty ? ["*"] : hosts { rules.sites[host, default: []].append(call) }
                for host in except { rules.sites[host, default: []].append(~call) }
            case .exception(let call, let hosts):
                let mark = call.map { ~index(of: $0) } ?? Int.min
                for host in hosts.isEmpty ? ["*"] : hosts { rules.sites[host, default: []].append(mark) }
            case .skip:
                break
            }
        }

        private mutating func index(of call: String) -> Int {
            if let known = indices[call] { return known }
            rules.calls.append(call)
            indices[call] = rules.calls.count - 1
            return rules.calls.count - 1
        }
    }
}
