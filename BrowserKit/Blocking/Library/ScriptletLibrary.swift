import Foundation

/// Browser's library of uBlock Origin's scriptlets, under its names and
/// with its behaviour, written as JavaScript that runs in the page's own
/// world. The JavaScript is held in sections, one to a file beside this
/// one, and put together here into the one script a web view is given.
enum ScriptletLibrary {
    /// The script for a web view whose frames are on `hosts`, each with the
    /// calls it runs (as JSON: `["json-prune","adPlacements"]`). Every
    /// frame gets the script; a frame on a host it doesn't name runs none
    /// of it.
    static func source(for hosts: [String: [String]]) -> String {
        let table = hosts.map { host, calls in "\(quote(host)):[\(calls.joined(separator: ","))]" }
        return #"""
        (() => {
        'use strict';
        const table = {\#(table.joined(separator: ","))};
        \#(body)
        """#
    }

    /// Every scriptlet the library has: its `'name'(…) {` entries.
    static let names: Set<String> = Set(
        scriptlets.matches(of: /^  '([^']+)'\(/.anchorsMatchLineEndings()).map { String($0.1) }
    )

    /// Everything after the table, the same for every page.
    private static let body = [opening, helpers, pruning, editing, bodies, scriptlets, closing].joined(separator: "\n\n")

    /// A frame finds its own calls by its host (a frame with none, such as
    /// `about:blank`, by its parent's), then takes the page's own
    /// functions before any of its scripts can replace them.
    private static let opening = #"""
    let host = location.hostname;
    if (host === '') { try { host = parent.location.hostname; } catch {} }
    const calls = table[host];
    if (calls === undefined) return;

    // The page's own functions, taken before any of its scripts run.
    const N = {
      apply: Reflect.apply, construct: Reflect.construct, define: Object.defineProperty,
      descriptor: Object.getOwnPropertyDescriptor, keys: Object.keys, hasOwn: Object.hasOwn,
      parse: JSON.parse, stringify: JSON.stringify, Proxy, RegExp, Error, ReferenceError,
      Response: self.Response, Request: self.Request, Promise, MutationObserver: self.MutationObserver,
      setTimeout: self.setTimeout, now: Date.now, random: Math.random,
    };
    const magic = String.fromCharCode(Date.now() % 26 + 97) + Math.floor(N.random() * 982451653 + 982451653).toString(36);
    self.addEventListener('error', event => {
      if (typeof event.message === 'string' && event.message.includes(magic)) event.preventDefault();
    }, true);
    """#

    /// The frame's calls run in the lists' order. One that throws doesn't
    /// stop the rest.
    private static let closing = #"""
    for (const [name, ...args] of calls) {
      try { S[name]?.(...args); } catch {}
    }
    })();
    """#

    /// `text` as a JavaScript string, quotes and all.
    private static func quote(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]) else { return "\"\"" }
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
