import Foundation

/// A scriptlet filter (`example.com##+js(json-prune, adPlacements)`), read
/// into the call it makes and the hosts it makes it on.
enum ScriptletFilter {
    /// Runs `call` on `hosts` (everywhere, if none), but not on `except`.
    case run(call: String, hosts: [String], except: [String])
    /// `#@#+js(…)`: takes `call` back on `hosts`, or with no call, every
    /// scriptlet.
    case exception(call: String?, hosts: [String])
    /// One Browser can't run: a scriptlet the library doesn't have, a
    /// `trusted-` one from a list that isn't trusted, a filter it can't read.
    case skip

    /// Nil for a line that isn't a scriptlet filter. `trusted`: whether the
    /// line's list may run `trusted-` scriptlets, which can run any code.
    init?(_ line: String, trusted: Bool) {
        let isException: Bool
        let marker: Range<String.Index>
        if let found = line.range(of: "#@#+js(") {
            (isException, marker) = (true, found)
        } else if let found = line.range(of: "##+js(") {
            (isException, marker) = (false, found)
        } else {
            return nil
        }
        self = .skip
        guard line.hasSuffix(")") else { return }
        let hosts = line[..<marker.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !hosts.contains(where: { $0.contains("/") }) else { return }

        var call: String?
        let body = line[marker.upperBound ..< line.index(before: line.endIndex)]
        if !body.trimmingCharacters(in: .whitespaces).isEmpty {
            var arguments = ScriptletFilter.arguments(body)
            guard let name = ScriptletFilter.canonical(arguments[0]), trusted || !name.hasPrefix("trusted-") || isException else { return }
            arguments[0] = name
            guard let json = ScriptletFilter.json(arguments) else { return }
            call = json
        }

        let included = hosts.filter { !$0.hasPrefix("~") && !$0.isEmpty }
        if isException {
            self = .exception(call: call, hosts: included)
        } else if let call {
            self = .run(call: call, hosts: included, except: hosts.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) })
        }
    }

    /// A call as the page's script takes it: `["json-prune","adPlacements"]`.
    private static func json(_ call: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: call, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `name, arg, 'quoted, arg', arg\, with comma`. Always at least one,
    /// the name.
    static func arguments(_ body: some StringProtocol) -> [String] {
        let characters = Array(body)
        var arguments: [String] = []
        var at = 0
        while true {
            while at < characters.count, characters[at] == " " { at += 1 }
            if let (quoted, end) = quoted(characters, from: at) {
                arguments.append(quoted)
                at = end
                while at < characters.count, characters[at] != "," { at += 1 }
            } else {
                var argument = ""
                while at < characters.count, characters[at] != "," {
                    // `\,` is a comma in the argument, not the end of it.
                    if characters[at] == "\\", at + 1 < characters.count, characters[at + 1] == "," { at += 1 }
                    argument.append(characters[at])
                    at += 1
                }
                arguments.append(argument.trimmingCharacters(in: .whitespaces))
            }
            guard at < characters.count else { return arguments }
            at += 1
        }
    }

    /// An argument in quotes starting at `start`, and where it ends: only
    /// when the closing quote is the last thing before the next comma.
    private static func quoted(_ characters: [Character], from start: Int) -> (String, end: Int)? {
        guard start < characters.count, ["'", "\"", "`"].contains(characters[start]) else { return nil }
        let quote = characters[start]
        guard let close = characters.indices.dropFirst(start + 1).first(where: { characters[$0] == quote && characters[$0 - 1] != "\\" }),
              characters[(close + 1)...].first(where: { $0 != " " }).map({ $0 == "," }) ?? true
        else { return nil }
        let text = String(characters[(start + 1) ..< close]).replacingOccurrences(of: "\\\(quote)", with: String(quote))
        return (text, close + 1)
    }

    /// The library's name for a scriptlet, or nil if it has none.
    private static func canonical(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(".js") { name.removeLast(3) }
        name = aliases[name] ?? name
        return ScriptletLibrary.names.contains(name) ? name : nil
    }

    /// The short and the older names the lists use.
    private static let aliases: [String: String] = [
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
        "fuckadblock.js-3.2.0": "nofab",
        "prevent-eval-if": "noeval-if",
    ]
}
