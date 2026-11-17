import Foundation

/// What the filter lists compile into: plain values, so they can be made
/// off the main actor and handed across to it.
struct CompiledFilters: Sendable {
    /// WebKit content rule lists, each as its JSON.
    var lists: [String]
    /// The `+js(…)` rules the `Scriptlets` library runs.
    var scriptlets: ScriptletRules
    /// How many rules that is in all.
    var ruleCount: Int
}

/// Adblock Plus / uBlock Origin filter syntax, turned into WebKit content
/// rules, plus the scriptlets (`+js(…)`) the `Scriptlets` library runs.
/// What WebKit can enforce inside its networking and its style resolver
/// is kept; procedural cosmetics and redirects are dropped.
struct FilterCompiler {
    private var blocks: [ContentRule] = []
    private var exceptions: [ContentRule] = []
    private var hides = Hides()
    private var scriptlets = ScriptletRules.Builder()
    /// The lists overlap, line for line.
    private var lines = Set<String>()
    /// And the same rule, written differently, comes out the same here.
    /// Compared as values, never as their encoded Data: Data hashes only
    /// its first bytes, and every rule's JSON starts the same, so a
    /// Set<Data> is quadratic here.
    private var rules = Set<ContentRule>()

    /// `limit`: WebKit takes at most 150,000 rules in one list.
    static func compile(_ lists: [FilterList], limit: Int = 150_000) throws -> CompiledFilters {
        var compiler = FilterCompiler()
        for list in lists {
            list.text.enumerateLines { line, _ in compiler.add(line, trusted: list.isTrusted) }
        }
        return try compiler.compiled(limit: limit)
    }

    private mutating func add(_ raw: String, trusted: Bool) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        // Foundation hands each line over as an NSString, which every
        // search below would cross the bridge for: a string of Swift's own.
        line.makeContiguousUTF8()
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), lines.insert(line).inserted else { return }
        // Scriptlet and cosmetic filters all have a `#` in them. Most lines
        // have none, and aren't searched for the dozen ways of writing one.
        if line.utf8.contains(UInt8(ascii: "#")) {
            if let filter = ScriptletFilter(line, trusted: trusted) { return scriptlets.add(filter) }
            if let filter = CosmeticFilter(line) { return hides.add(filter) }
        }
        if let rule = NetworkFilter.rule(for: line), rules.insert(rule).inserted {
            if rule.isException { exceptions.append(rule) } else { blocks.append(rule) }
        }
    }

    private func compiled(limit: Int) throws -> CompiledFilters {
        let hides = hides.rules
        // An exception only undoes rules in its own list, so every list
        // ends with all of them.
        let room = max(1000, limit - exceptions.count)
        let lists = try [blocks, hides].flatMap { rules in
            try stride(from: 0, to: rules.count, by: room).map { start in
                try ContentRule.encode(rules[start ..< min(start + room, rules.count)] + exceptions)
            }
        }
        return CompiledFilters(lists: lists, scriptlets: scriptlets.rules,
                               ruleCount: blocks.count + hides.count + exceptions.count + scriptlets.rules.count)
    }
}
