import Foundation

/// A script as it goes into a page.
@MainActor
struct UserscriptSource {
    let script: Userscript
    let meta: UserscriptMeta
    let bridge: UserscriptBridge

    /// Each API a script can be granted, by its grant, with the name its
    /// function takes it under (`GM.getValue` goes by the same grant), in
    /// the order the function takes them.
    private static let apis: [(grant: String, name: String)] = [
        ("getvalue", "GM_getValue"), ("setvalue", "GM_setValue"), ("deletevalue", "GM_deleteValue"),
        ("listvalues", "GM_listValues"), ("getvalues", "GM_getValues"), ("setvalues", "GM_setValues"),
        ("deletevalues", "GM_deleteValues"), ("addvaluechangelistener", "GM_addValueChangeListener"),
        ("removevaluechangelistener", "GM_removeValueChangeListener"), ("getresourcetext", "GM_getResourceText"),
        ("getresourceurl", "GM_getResourceURL"), ("addstyle", "GM_addStyle"), ("addelement", "GM_addElement"),
        ("openintab", "GM_openInTab"), ("registermenucommand", "GM_registerMenuCommand"),
        ("unregistermenucommand", "GM_unregisterMenuCommand"), ("notification", "GM_notification"),
        ("setclipboard", "GM_setClipboard"), ("xmlhttprequest", "GM_xmlhttpRequest"), ("download", "GM_download"),
        ("log", "GM_log"),
    ]

    /// The script as a function of its own, which the runtime calls at its
    /// @run-at with the GM APIs it was granted: what it declares stays out
    /// of the page. It carries its values as they are now.
    func wrapped(rules: UserscriptRules, values: [String: String]) -> String {
        let grants = meta.grants
        let granted = UserscriptSource.apis.filter { grants.contains($0.grant) }
        var parameters = ["GM_info", "GM", "unsafeWindow"] + granted.map(\.name)
        // window.close and window.focus: the script's own `window`, which
        // has them; the page's keeps its own.
        if grants.contains("window.close") || grants.contains("window.focus") { parameters.append("window") }
        let settings: [String: Any] = [
            "id": script.id,
            "secret": bridge.secret,
            "handler": UserscriptBridge.handlerName,
            "hook": bridge.hook(for: script.id),
            "include": rules.include.map(\.pair),
            "exclude": rules.exclude.map(\.pair),
            "everywhere": rules.everywhere,
            "noframes": meta.noframes,
            // An @unwrap script's function is for frames: the top frame has it as written.
            "framesOnly": meta.unwrap,
            "runAt": meta.runAt,
            "grants": Array(grants),
            "apis": granted.map { [$0.grant, $0.name] },
            "params": parameters,
            "values": values.map { [$0.key, $0.value] },
            "resources": script.resources.map { [$0.key, $0.value.mime, $0.value.data] },
            "info": info,
        ]
        let function = meta.topLevelAwait ? "async function" : "function"
        // The script is a function of its own, outside the one that holds
        // the secret: nothing it does can reach it.
        return "(function () {\nconst __userscript = \(function) (\(parameters.joined(separator: ", "))) {\n\(body)\n};\n"
            + "(\(UserscriptRuntime.source))(__userscript, \(UserscriptSource.json(settings)));\n})();\n\(sourceURL)"
    }

    /// An @unwrap script for the top frame: as written, at the page's top
    /// level, with no GM APIs. What it declares is the page's.
    var unwrapped: String {
        body + "\n" + sourceURL
    }

    /// Goes beside an @unwrap script, which can't say so itself: tells the
    /// bridge that the script started in this page.
    var started: String {
        """
        (() => { const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[\(UserscriptSource.json(UserscriptBridge.handlerName))];
          if (h) h.postMessage({s: \(UserscriptSource.json(bridge.secret)), id: \(UserscriptSource.json(script.id)), instance: 'top' + Math.random(), op: 'run', args: null}).catch(() => {}); })();
        """
    }

    /// The @require files in order, then the script.
    private var body: String {
        meta.require.compactMap { script.requires[$0] }.map { $0 + "\n;\n" }.joined() + script.source
    }

    /// The name the script goes by in Web Inspector and in its errors.
    private var sourceURL: String {
        let name = meta.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        return "//# sourceURL=userscript:///\(name).user.js"
    }

    /// `GM_info`. It says Violentmonkey, which is what scripts written for
    /// it look for.
    private var info: [String: Any] {
        [
            "script": [
                "name": meta.name, "namespace": meta.namespace, "version": meta.version,
                "description": meta.description, "author": meta.author, "homepage": meta.homepage, "icon": meta.icon,
                "matches": meta.match, "includes": meta.include, "excludes": meta.exclude, "excludeMatches": meta.excludeMatch,
                "grant": meta.grant, "require": meta.require, "resources": meta.resources.map { ["name": $0.name, "url": $0.url] },
                "runAt": meta.runAt, "noframes": meta.noframes, "unwrap": meta.unwrap, "injectInto": meta.injectInto,
                "updateURL": meta.updateURL, "downloadURL": meta.downloadURL,
            ] as [String: Any],
            "scriptMetaStr": meta.block,
            "scriptHandler": "Violentmonkey",
            "version": "2.31.0",
            "uuid": script.id,
            "injectInto": meta.injectInto,
            "isIncognito": false,
            "platform": ["arch": "arm64", "browserName": "safari", "os": "mac"],
        ]
    }

    /// `value` as JavaScript can read it.
    nonisolated static func json(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
