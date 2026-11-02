import Foundation
import WebKit

/// The filter lists' scriptlets (`example.com##+js(json-prune, adPlacements)`):
/// what a list asks to run in a site's pages before any of the site's own
/// scripts, where blocking a request can't help (YouTube's ads come from the
/// same servers as its videos).
///
/// Nothing runs on a site no rule names. A page's scriptlets are worked out
/// here, from its host, as each frame's navigation is decided, and only
/// those reach the page.
public struct ScriptletRules: Codable, Sendable {
    /// Each call as JSON: `["json-prune","adPlacements"]`.
    var calls: [String] = []
    /// A host, an entity (`google.*`) or `*`, to the calls it runs; `~i`
    /// for an exception to call `i`, `Int.min` for "none here".
    var sites: [String: [Int]] = [:]
    private var index: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey { case calls, sites }

    public var count: Int { calls.count }

    /// The calls for a page on `host`, as JSON.
    func calls(for host: String) -> [String] {
        var run = Set<Int>(), off = Set<Int>()
        for key in ScriptletRules.keys(for: host) {
            for i in sites[key] ?? [] {
                if i >= 0 { run.insert(i) } else { off.insert(i == Int.min ? i : ~i) }
            }
        }
        if off.contains(Int.min) { return [] }
        return run.subtracting(off).sorted().map { calls[$0] }
    }

    /// Every name a rule for `host` can be filed under.
    static func keys(for host: String) -> [String] {
        let host = host.lowercased()
        let labels = host.split(separator: ".")
        var keys = (0 ..< labels.count).map { labels[$0...].joined(separator: ".") }
        // `google.*`: the site's name with any public suffix after it.
        if let suffix = Site.suffix(of: host), host.count > suffix.count {
            let named = host.dropLast(suffix.count + 1).split(separator: ".")
            keys += (0 ..< named.count).map { named[$0...].joined(separator: ".") + ".*" }
        }
        return keys + ["*"]
    }

    /// Takes a `##+js(…)` or `#@#+js(…)` line; false if it isn't one, or is
    /// one Browser can't run.
    mutating func add(_ line: String, trusted: Bool) -> Bool? {
        let exception: Bool
        let marker: Range<String.Index>
        if let r = line.range(of: "#@#+js(") { exception = true; marker = r }
        else if let r = line.range(of: "##+js(") { exception = false; marker = r }
        else { return nil }
        guard line.hasSuffix(")") else { return false }
        let body = String(line[marker.upperBound ..< line.index(before: line.endIndex)])
        let domains = line[..<marker.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !domains.contains(where: { $0.contains("/") }) else { return false }

        var call = -1
        if !body.trimmingCharacters(in: .whitespaces).isEmpty {
            var args = ScriptletRules.arguments(body)
            guard !args.isEmpty, let name = ScriptletRules.canonical(args[0]),
                  trusted || !name.hasPrefix("trusted-") || exception
            else { return false }
            args[0] = name
            guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.withoutEscapingSlashes]) else { return false }
            let json = String(decoding: data, as: UTF8.self)
            if let i = index[json] { call = i } else {
                call = calls.count
                calls.append(json)
                index[json] = call
            }
        } else if !exception {
            return false
        }

        let included = domains.filter { !$0.hasPrefix("~") && !$0.isEmpty }
        let excluded = domains.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) }
        if exception {
            for d in included.isEmpty ? ["*"] : included { sites[d, default: []].append(call < 0 ? Int.min : ~call) }
        } else {
            for d in included.isEmpty ? ["*"] : included { sites[d, default: []].append(call) }
            for d in excluded { sites[d, default: []].append(~call) }
        }
        return true
    }

    /// `name, arg, 'quoted, arg', arg\, with comma`.
    static func arguments(_ body: String) -> [String] {
        var args: [String] = []
        var chars = Array(body)[...]
        while true {
            while chars.first == " " { chars.removeFirst() }
            var arg = ""
            if let quote = chars.first, quote == "'" || quote == "\"" || quote == "`",
               let close = chars.dropFirst().indices.first(where: { chars[$0] == quote && chars[$0 - 1] != "\\" }),
               chars[(close + 1)...].first(where: { $0 != " " }).map({ $0 == "," }) ?? true {
                arg = String(chars[(chars.startIndex + 1) ..< close]).replacingOccurrences(of: "\\\(quote)", with: String(quote))
                chars = chars[(close + 1)...]
                while let c = chars.first, c != "," { chars.removeFirst() }
            } else {
                while let c = chars.first, c != "," {
                    chars.removeFirst()
                    if c == "\\", chars.first == "," { arg.append(","); chars.removeFirst() } else { arg.append(c) }
                }
                arg = arg.trimmingCharacters(in: .whitespaces)
            }
            args.append(arg)
            guard chars.first == "," else { break }
            chars.removeFirst()
        }
        return args
    }

    /// The library's name for a scriptlet, or nil if it has none.
    static func canonical(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(".js") { name.removeLast(3) }
        name = aliases[name] ?? name
        return ScriptletLibrary.names.contains(name) ? name : nil
    }

    static let aliases: [String: String] = [
        "aopr": "abort-on-property-read", "aopw": "abort-on-property-write",
        "acs": "abort-current-script", "acis": "abort-current-script", "abort-current-inline-script": "abort-current-script",
        "aost": "abort-on-stack-trace",
        "set": "set-constant", "trusted-set": "trusted-set-constant",
        "nowoif": "no-window-open-if", "window.open-defuser": "no-window-open-if", "prevent-window-open": "no-window-open-if",
        "nostif": "no-setTimeout-if", "setTimeout-defuser": "no-setTimeout-if", "prevent-setTimeout": "no-setTimeout-if",
        "nosiif": "no-setInterval-if", "setInterval-defuser": "no-setInterval-if", "prevent-setInterval": "no-setInterval-if",
        "norafif": "no-requestAnimationFrame-if", "prevent-requestAnimationFrame": "no-requestAnimationFrame-if",
        "nano-stb": "nano-setTimeout-booster", "adjust-setTimeout": "nano-setTimeout-booster",
        "nano-sib": "nano-setInterval-booster", "adjust-setInterval": "nano-setInterval-booster",
        "rmnt": "remove-node-text",
        "rpnt": "trusted-replace-node-text", "replace-node-text": "trusted-replace-node-text", "trusted-rpnt": "trusted-replace-node-text",
        "aeld": "addEventListener-defuser", "prevent-addEventListener": "addEventListener-defuser",
        "prevent-fetch": "no-fetch-if", "prevent-xhr": "no-xhr-if",
        "trusted-rpfr": "trusted-replace-fetch-response",
        "ra": "remove-attr", "rc": "remove-class",
        "cookie-remover": "remove-cookie",
        "nofab": "nofab", "fuckadblock.js-3.2.0": "nofab",
        "prevent-eval-if": "noeval-if",
    ]
}

/// Puts each page's scriptlets into its web view.
@MainActor
public final class Scriptlets {
    public static let shared = Scriptlets()

    public internal(set) var rules = ScriptletRules()

    private final class Installed {
        var hosts: [String: [String]] = [:]
        var script: WKUserScript?
    }

    private let installed = NSMapTable<WKUserContentController, Installed>.weakToStrongObjects()

    /// Before a frame in `controller`'s web view loads `url`: that host's
    /// scriptlets join the ones its other frames already have.
    func prepare(_ controller: WKUserContentController, for url: URL?) {
        guard let scheme = url?.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url?.host?.lowercased(), !host.isEmpty
        else { return }
        let state = installed.object(forKey: controller) ?? {
            let state = Installed()
            installed.setObject(state, forKey: controller)
            return state
        }()
        guard state.hosts[host] == nil else { return }
        let calls = rules.calls(for: host)
        guard !calls.isEmpty else { return }
        state.hosts[host] = calls
        let table = "{" + state.hosts.map { host, calls in
            "\(ScriptletLibrary.quote(host)):[\(calls.joined(separator: ","))]"
        }.joined(separator: ",") + "}"
        let script = WKUserScript(source: ScriptletLibrary.source(table: table), injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false, in: .page)
        // First, before anything else runs in the page.
        let others = controller.userScripts.filter { $0 !== state.script }
        controller.removeAllUserScripts()
        controller.addUserScript(script)
        others.forEach(controller.addUserScript)
        state.script = script
    }
}

extension WKUserContentController {
    /// Takes one script out, keeping the rest in order.
    func remove(_ script: WKUserScript) {
        let others = userScripts.filter { $0 !== script }
        guard others.count != userScripts.count else { return }
        removeAllUserScripts()
        others.forEach(addUserScript)
    }
}
