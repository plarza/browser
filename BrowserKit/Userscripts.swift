#if os(macOS)
import AppKit
#endif
import Foundation
import JavaScriptCore
import UserNotifications
import WebKit

/// An installed userscript: its source as written, and what it fetched
/// when it was installed (@require and @resource), so it runs without
/// asking the network for anything.
public struct Userscript: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var source: String
    public var enabled = true
    /// Where it was installed from; updates come from its @updateURL,
    /// @downloadURL, or here.
    public var installURL: String?
    /// Changed here since it was installed: updates leave it alone.
    public var edited = false
    /// @require URL to its text.
    public var requires: [String: String] = [:]
    /// @resource name to what it holds.
    public var resources: [String: Resource] = [:]
    public var installed = Date()
    public var updated = Date()

    public struct Resource: Codable, Equatable, Sendable {
        var url: String
        var mime: String
        /// Base64.
        var data: String
    }

    public var meta: UserscriptMeta { UserscriptMeta.parse(source) ?? UserscriptMeta() }
    public var name: String { let n = meta.name; return n.isEmpty ? "Untitled" : n }
}

public struct UserscriptError: LocalizedError {
    public let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// Browser's userscript runner, compatible with Violentmonkey's scripts and
/// its GM_* and GM.* APIs.
///
/// As with the scriptlets, the app decides which scripts a page gets as
/// each frame's navigation is decided, and only those reach it; a site no
/// script names runs none. Each runs before the page's own scripts (and
/// then waits for its @run-at), in the page's world or, with
/// `@inject-into content`, in a world of Browser's own.
///
/// The GM APIs reach the app through one message handler. A page can see
/// that handler where a script runs in its world, so every message carries
/// a secret made at launch that only the scripts hold; a message without it
/// does nothing.
@MainActor
public final class Userscripts: NSObject, ObservableObject {
    public static let shared = Userscripts()
    /// Posted with the web view whose scripts or menu commands changed.
    public static let pageChanged = Notification.Name("BrowserUserscriptsPageChanged")

    @Published public private(set) var scripts: [Userscript] = []

    static let handlerName = "browserUserscripts"
    static let world = WKContentWorld.world(name: "Userscripts")
    private let secret = Userscripts.random(32)
    private let hookBase = "__bu" + Userscripts.random(12)

    private var values: [String: [String: String]] = [:]
    /// Raised whenever a script's source, switch or values change, so a web
    /// view's copy is rebuilt at its next load.
    private var revision: [String: Int] = [:]
    private var rules: [String: UserscriptRules] = [:]
    private var pendingWrites: [String: Task<Void, Never>] = [:]

    private override init() {
        super.init()
        load()
        NotificationCenter.default.addObserver(forName: Tab.didClose, object: nil, queue: .main) { note in
            guard let tab = note.object as? Tab else { return }
            MainActor.assumeIsolated { Userscripts.shared.tabClosed(tab) }
        }
    }

    private static func random(_ count: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0 ..< count).map { _ in chars[Int.random(in: 0 ..< chars.count)] })
    }

    // MARK: Storage

    private static var folder: URL {
        let url = Store.url("Userscripts")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Userscripts.folder, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Userscript] = []
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasSuffix(".values.json") {
            guard let data = try? Data(contentsOf: file), let script = try? JSONDecoder().decode(Userscript.self, from: data) else { continue }
            loaded.append(script)
            if let data = try? Data(contentsOf: Userscripts.folder.appendingPathComponent("\(script.id).values.json")),
               let stored = try? JSONDecoder().decode([String: String].self, from: data) {
                values[script.id] = stored
            }
        }
        scripts = loaded.sorted { $0.installed < $1.installed }
        for script in scripts { rules[script.id] = UserscriptRules(script.meta) }
    }

    private func write(_ script: Userscript) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(script) else { return }
        try? data.write(to: Userscripts.folder.appendingPathComponent("\(script.id).json"), options: [.atomic, .completeFileProtection])
    }

    /// Values are written a moment after they settle: a script that sets
    /// one on every scroll doesn't write on every scroll.
    private func writeValues(_ id: String) {
        pendingWrites[id]?.cancel()
        pendingWrites[id] = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            flushValues(id)
        }
    }

    private func flushValues(_ id: String) {
        pendingWrites[id] = nil
        let file = Userscripts.folder.appendingPathComponent("\(id).values.json")
        guard scripts.contains(where: { $0.id == id }) else { return }
        if let data = try? JSONEncoder().encode(values[id] ?? [:]) {
            try? data.write(to: file, options: [.atomic, .completeFileProtection])
        }
    }

    /// Values still waiting to be written, written now: Browser is quitting.
    public func flush() {
        for id in Array(pendingWrites.keys) { pendingWrites[id]?.cancel(); flushValues(id) }
    }

    private func put(_ script: Userscript) {
        if let i = scripts.firstIndex(where: { $0.id == script.id }) { scripts[i] = script } else { scripts.append(script) }
        rules[script.id] = UserscriptRules(script.meta)
        write(script)
        changed(script.id)
    }

    public func script(_ id: String) -> Userscript? { scripts.first { $0.id == id } }

    /// Its values as JSON, for the editor's view of them.
    public func values(of id: String) -> [String: String] { values[id] ?? [:] }

    // MARK: Installing and editing

    /// Installs a script, or replaces the one with the same @name and
    /// @namespace (keeping its values and its switch). Fetches its
    /// @require and @resource files first.
    @discardableResult
    public func install(_ source: String, from url: URL?) async throws -> Userscript {
        guard let meta = UserscriptMeta.parse(source), !meta.name.isEmpty else {
            throw UserscriptError("This isn't a userscript: it has no ==UserScript== block with a @name.")
        }
        if let error = Userscripts.syntaxError(source, meta) { throw UserscriptError(error) }
        let existing = scripts.first { $0.meta.name == meta.name && $0.meta.namespace == meta.namespace }
        let (requires, resources) = try await fetchDependencies(meta, base: url, cached: nil)
        var script = existing ?? Userscript(id: UUID().uuidString.lowercased(), source: source)
        script.source = source
        script.installURL = url?.absoluteString ?? script.installURL
        script.edited = false
        script.requires = requires
        script.resources = resources
        script.updated = Date()
        put(script)
        return script
    }

    /// The installed script a source would replace, if any.
    public func installed(like source: String) -> Userscript? {
        guard let meta = UserscriptMeta.parse(source), !meta.name.isEmpty else { return nil }
        return scripts.first { $0.meta.name == meta.name && $0.meta.namespace == meta.namespace }
    }

    /// The editor's Save. A script that doesn't parse isn't saved.
    public func save(_ id: String, source: String) async throws {
        guard var script = script(id) else { return }
        guard let meta = UserscriptMeta.parse(source) else {
            throw UserscriptError("A script needs its ==UserScript== block.")
        }
        if let error = Userscripts.syntaxError(source, meta) { throw UserscriptError(error) }
        let (requires, resources) = try await fetchDependencies(meta, base: script.installURL.flatMap(URL.init(string:)), cached: script)
        // Edited while fetching: the newest wins.
        guard self.script(id) != nil else { return }
        script.source = source
        script.edited = true
        script.requires = requires
        script.resources = resources
        script.updated = Date()
        put(script)
    }

    /// A new script, ready to edit.
    @discardableResult
    public func create() -> Userscript {
        var name = "New Script"
        var n = 2
        while scripts.contains(where: { $0.meta.name == name }) { name = "New Script \(n)"; n += 1 }
        var script = Userscript(id: UUID().uuidString.lowercased(), source: """
        // ==UserScript==
        // @name        \(name)
        // @namespace   Browser Scripts
        // @match       https://example.com/*
        // @grant       none
        // @version     1.0
        // ==/UserScript==


        """)
        script.edited = true
        put(script)
        return script
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        guard var script = script(id), script.enabled != on else { return }
        script.enabled = on
        put(script)
    }

    public func remove(_ id: String) {
        pendingWrites[id]?.cancel()
        pendingWrites[id] = nil
        scripts.removeAll { $0.id == id }
        values[id] = nil
        rules[id] = nil
        for name in ["\(id).json", "\(id).values.json"] {
            try? FileManager.default.removeItem(at: Userscripts.folder.appendingPathComponent(name))
        }
        changed(id)
    }

    /// Every web view drops its copy of the script; the next load in each
    /// gets the new one, if it still matches.
    private func changed(_ id: String) {
        revision[id, default: 0] += 1
        for controller in installed.keyEnumerator().allObjects as! [WKUserContentController] {
            guard let state = installed.object(forKey: controller) else { continue }
            for key in state.scripts.keys where key == id || key.hasPrefix(id + "#") {
                state.scripts.removeValue(forKey: key)?.scripts.forEach(controller.remove)
            }
        }
    }

    private func fetchDependencies(_ meta: UserscriptMeta, base: URL?, cached: Userscript?) async throws -> ([String: String], [String: Userscript.Resource]) {
        var requires: [String: String] = [:]
        var resources: [String: Userscript.Resource] = [:]
        let session = Engine.session(timeout: 30)
        defer { session.finishTasksAndInvalidate() }
        for raw in meta.require where requires[raw] == nil {
            if let text = cached?.requires[raw] { requires[raw] = text; continue }
            guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
                  let (data, _) = try? await Userscripts.fetch(url, in: session)
            else { throw UserscriptError("Couldn't fetch @require \(raw)") }
            let text = String(decoding: data, as: UTF8.self)
            if let error = Userscripts.syntaxError(text, nil) { throw UserscriptError("@require \(raw): \(error)") }
            requires[raw] = text
        }
        for resource in meta.resources {
            if let kept = cached?.resources[resource.name], kept.url == resource.url { resources[resource.name] = kept; continue }
            guard let url = URL(string: resource.url, relativeTo: base)?.absoluteURL,
                  let (data, mime) = try? await Userscripts.fetch(url, in: session)
            else { throw UserscriptError("Couldn't fetch @resource \(resource.name)") }
            resources[resource.name] = .init(url: resource.url, mime: mime, data: data.base64EncodedString())
        }
        return (requires, resources)
    }

    private static func fetch(_ url: URL, in session: URLSession) async throws -> (Data, String) {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return (data, response.mimeType ?? "application/octet-stream")
    }

    /// What JavaScriptCore says is wrong with it, as a userscript's body, or nil.
    public static func syntaxError(_ source: String, _ meta: UserscriptMeta?) -> String? {
        guard let context = JSContext() else { return nil }
        var error: String?
        context.exceptionHandler = { _, exception in
            let line = Int(exception?.objectForKeyedSubscript("line")?.toInt32() ?? 1) - 1
            error = "Line \(max(line, 1)): \(exception?.toString() ?? "a syntax error")"
        }
        let fn = meta?.topLevelAwait == true ? "async function" : "function"
        context.evaluateScript("(\(fn) () {\n" + source + "\n})")
        return error
    }

    // MARK: Updates

    /// With the filter lists: once a day, checked every hour.
    public func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "userscript", actions: [], intentIdentifiers: [],
                                                                 options: [.customDismissAction])])
        updateIfDue()
        Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in Userscripts.shared.updateIfDue() }
        }
    }

    private func updateIfDue() {
        let last = Store.read(Date.self, "userscripts-checked.json") ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 60 * 60, scripts.contains(where: { !$0.edited }) else { return }
        Task { await checkForUpdates() }
    }

    /// Each script not edited here, from its @updateURL, @downloadURL or
    /// where it came from: installed again when its @version went up.
    public func checkForUpdates() async {
        Store.write(Date(), "userscripts-checked.json")
        let session = Engine.session(timeout: 30)
        defer { session.finishTasksAndInvalidate() }
        for script in scripts where !script.edited {
            let meta = script.meta
            let candidates = [meta.updateURL, meta.downloadURL, script.installURL ?? ""]
                .compactMap { URL(string: $0) }.filter { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
            guard let check = candidates.first,
                  let (data, _) = try? await Userscripts.fetch(check, in: session),
                  let latest = UserscriptMeta.parse(String(decoding: data, as: UTF8.self)),
                  UserscriptMeta.newer(latest.version, than: meta.version)
            else { continue }
            var source = String(decoding: data, as: UTF8.self)
            if check.path.hasSuffix(".meta.js") {
                guard let full = [latest.downloadURL, meta.downloadURL, script.installURL ?? ""].compactMap({ URL(string: $0) })
                    .first(where: { !$0.path.hasSuffix(".meta.js") && ["https", "http"].contains($0.scheme?.lowercased() ?? "") }),
                      let (code, _) = try? await Userscripts.fetch(full, in: session)
                else { continue }
                source = String(decoding: code, as: UTF8.self)
            }
            _ = try? await install(source, from: script.installURL.flatMap(URL.init(string:)) ?? check)
        }
    }

    // MARK: Pages

    private final class Installed {
        /// A script's id (and `#top` for an @unwrap script's top frame) to
        /// what it put in the web view.
        var scripts: [String: (scripts: [WKUserScript], revision: Int)] = [:]
        var worlds: Set<String> = []
    }

    private let installed = NSMapTable<WKUserContentController, Installed>.weakToStrongObjects()

    /// Before a frame in `controller`'s web view loads `url`: the scripts
    /// for that address join the ones the web view already has.
    ///
    /// An @unwrap script runs as written, at the top level of the page, so
    /// it can't check the address itself: its copy for the top frame is
    /// decided again at every top-frame navigation. In frames it runs in its
    /// own function, like any other.
    func prepare(_ controller: WKUserContentController, for url: URL?, mainFrame: Bool = true) {
        guard !scripts.isEmpty, let url, let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" || scheme == "file"
        else { return }
        let address = url.absoluteString
        let state = installed.object(forKey: controller) ?? {
            let state = Installed()
            installed.setObject(state, forKey: controller)
            return state
        }()
        func world(_ name: String) -> WKContentWorld {
            let world = name == "content" ? Userscripts.world : WKContentWorld.page
            if !state.worlds.contains(name) {
                controller.addScriptMessageHandler(self, contentWorld: world, name: Userscripts.handlerName)
                state.worlds.insert(name)
            }
            return world
        }
        for script in scripts {
            let meta = script.meta
            let matches = script.enabled && rules[script.id]?.matches(address) == true
            let current = revision[script.id, default: 0]
            if meta.unwrap {
                let key = script.id + "#top"
                if mainFrame {
                    if let have = state.scripts[key], !matches || have.revision != current {
                        have.scripts.forEach(controller.remove)
                        state.scripts[key] = nil
                    }
                    if matches, state.scripts[key] == nil {
                        var body = ""
                        for url in meta.require { if let text = script.requires[url] { body += text + "\n;\n" } }
                        body += script.source + "\n//# sourceURL=userscript:///\(Userscripts.file(meta)).user.js"
                        let raw = WKUserScript(source: body, injectionTime: meta.runAt == "document-start" ? .atDocumentStart : .atDocumentEnd,
                                               forMainFrameOnly: true, in: .page)
                        // Counted as running from Browser's own world, where the secret is safe.
                        let ran = WKUserScript(source: """
                        (() => { const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[\(Userscripts.quote(Userscripts.handlerName))];
                          if (h) h.postMessage({s: \(Userscripts.quote(secret)), id: \(Userscripts.quote(script.id)), instance: 'top' + Math.random(), op: 'run', args: null}).catch(() => {}); })();
                        """, injectionTime: raw.injectionTime, forMainFrameOnly: true, in: world("content"))
                        controller.addUserScript(raw)
                        controller.addUserScript(ran)
                        state.scripts[key] = ([raw, ran], current)
                    }
                }
                if meta.noframes { continue }
            }
            guard matches else { continue }
            if let have = state.scripts[script.id] {
                if have.revision == current { continue }
                have.scripts.forEach(controller.remove)
            }
            let user = WKUserScript(source: source(for: script, meta), injectionTime: .atDocumentStart,
                                    forMainFrameOnly: meta.noframes, in: world(meta.injectInto == "content" ? "content" : "page"))
            controller.addUserScript(user)
            state.scripts[script.id] = ([user], current)
        }
    }

    static func quote(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    static func file(_ meta: UserscriptMeta) -> String {
        meta.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
    }

    /// Legacy names for each grant, in the order a script's function takes them.
    static let legacyNames: [(String, String)] = [
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

    private func source(for script: Userscript, _ meta: UserscriptMeta) -> String {
        let grants = meta.unwrap ? [] : meta.grants
        var params = ["GM_info", "GM", "unsafeWindow"] + Userscripts.legacyNames.filter { grants.contains($0.0) }.map(\.1)
        // window.close and window.focus: the script's own `window`, which
        // has them; the page's keeps its own.
        if grants.contains("window.close") || grants.contains("window.focus") { params.append("window") }
        let rules = rules[script.id] ?? UserscriptRules(meta)
        var body = ""
        for url in meta.require { if let text = script.requires[url] { body += text + "\n;\n" } }
        body += script.source
        let info: [String: Any] = [
            "script": [
                "name": meta.name, "namespace": meta.namespace, "version": meta.version,
                "description": meta.description, "author": meta.author, "homepage": meta.homepage, "icon": meta.icon,
                "matches": meta.match, "includes": meta.include, "excludes": meta.exclude, "excludeMatches": meta.excludeMatch,
                "grant": meta.grant, "require": meta.require, "resources": meta.resources.map { ["name": $0.name, "url": $0.url] },
                "runAt": meta.runAt, "noframes": meta.noframes, "unwrap": meta.unwrap, "injectInto": meta.injectInto,
                "updateURL": meta.updateURL, "downloadURL": meta.downloadURL,
            ],
            "scriptMetaStr": meta.block,
            "scriptHandler": "Violentmonkey",
            "version": "2.31.0",
            "uuid": script.id,
            "injectInto": meta.injectInto,
            "isIncognito": false,
            "platform": ["arch": "arm64", "browserName": "safari", "os": "mac"],
        ]
        let config: [String: Any] = [
            "id": script.id,
            "secret": secret,
            "handler": Userscripts.handlerName,
            "hook": hookBase + script.id.replacingOccurrences(of: "-", with: ""),
            "include": rules.include,
            "exclude": rules.exclude,
            "everywhere": rules.everywhere,
            "noframes": meta.noframes,
            "framesOnly": meta.unwrap,
            "runAt": meta.runAt,
            "grants": Array(grants),
            "params": params,
            "values": (values[script.id] ?? [:]).map { [$0.key, $0.value] },
            "resources": script.resources.map { [$0.key, $0.value.mime, $0.value.data] },
            "info": info,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let fn = meta.topLevelAwait ? "async function" : "function"
        let file = Userscripts.file(meta)
        // The script is a function of its own, outside the one that holds
        // the secret: nothing it does can reach it.
        return "(function () {\nconst __userscript = \(fn) (\(params.joined(separator: ", "))) {\n\(body)\n};\n"
            + "(\(Userscripts.bootstrap))(__userscript, \(json));\n})();\n//# sourceURL=userscript:///\(file).user.js"
    }

    // MARK: What runs where

    /// A running copy of a script: a frame in a web view, in a world.
    fileprivate struct Instance {
        let id: String
        let script: String
        let frame: WKFrameInfo
        let world: WKContentWorld
        let hook: String
    }

    public struct MenuCommand: Identifiable {
        public let id: String
        public let caption: String
        public let script: String
        fileprivate let command: String
        fileprivate let instance: Instance
    }

    private final class Page {
        var instances: [Instance] = []
        var commands: [MenuCommand] = []
    }

    private let pages = NSMapTable<WKWebView, Page>.weakToStrongObjects()

    /// Who to tell about something that happens later: a tab a script
    /// opened closing, its notification clicked, its download's progress.
    private struct Listener {
        let instance: Instance
        weak var webView: WKWebView?
    }
    private var openedTabs: [String: (tab: Weak<Tab>, listener: Listener)] = [:]
    private var notifications: [String: (nid: String, listener: Listener)] = [:]
    private var downloads: [String: WKDownload] = [:]

    private func push(_ listener: Listener, _ message: [String: Any]) async {
        guard let webView = listener.webView else { return }
        _ = try? await webView.callAsyncJavaScript("window[h](m)", arguments: ["h": listener.instance.hook, "m": message],
                                                   in: listener.instance.frame, contentWorld: listener.instance.world)
    }

    private func tabClosed(_ tab: Tab) {
        for (key, entry) in openedTabs where entry.tab.value === tab || entry.tab.value == nil {
            openedTabs[key] = nil
            Task { await push(entry.listener, ["type": "tabclosed", "tab": key]) }
        }
    }

    private final class Weak<T: AnyObject> { weak var value: T?; init(_ value: T) { self.value = value } }

    /// A new document in the main frame: what ran before has gone.
    func pageChanged(_ webView: WKWebView) {
        guard pages.object(forKey: webView) != nil else { return }
        pages.removeObject(forKey: webView)
        NotificationCenter.default.post(name: Userscripts.pageChanged, object: webView)
    }

    /// The scripts for the page a web view shows: each that matches it,
    /// on or off, whether it ran, and its menu commands.
    public func scripts(on webView: WKWebView?) -> [(script: Userscript, running: Bool, commands: [MenuCommand])] {
        guard let webView, let url = webView.url?.absoluteString else { return [] }
        let page = pages.object(forKey: webView)
        let ran = Set(page?.instances.map(\.script) ?? [])
        return scripts.compactMap { script in
            let runs = ran.contains(script.id)
            guard runs || rules[script.id]?.matches(url) == true else { return nil }
            return (script, runs, page?.commands.filter { $0.script == script.id } ?? [])
        }
    }

    public func perform(_ command: MenuCommand, in webView: WKWebView) {
        Task {
            _ = try? await webView.callAsyncJavaScript("window[h]({type: 'menu', cmd: c})", arguments: ["h": command.instance.hook, "c": command.command],
                                                       in: command.instance.frame, contentWorld: command.instance.world)
        }
    }

    /// Tells every other running copy of a script that a value changed.
    private func broadcast(_ id: String, key: String, value: String?, from sender: String) {
        for webView in pages.keyEnumerator().allObjects as! [WKWebView] {
            for instance in pages.object(forKey: webView)?.instances ?? [] where instance.script == id && instance.id != sender {
                Task {
                    _ = try? await webView.callAsyncJavaScript("window[h]({type: 'value', key: k, value: v})",
                                                               arguments: ["h": instance.hook, "k": key, "v": value ?? NSNull()],
                                                               in: instance.frame, contentWorld: instance.world)
                }
            }
        }
    }

    // MARK: Requests

    private var requests: [String: () -> Void] = [:]

    private func request(_ args: [String: Any], webView: WKWebView?, listener: Listener) async -> Any {
        let reqID = args["reqId"] as? String ?? UUID().uuidString
        guard var url = (args["url"] as? String).flatMap(URL.init(string:)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "")
        else { return ["error": "Only http and https addresses can be fetched."] }
        // HTTPS-only, as every load is, except to this Mac.
        if url.scheme?.lowercased() == "http", !Tab.isLoopback(url.host), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.scheme = "https"
            if parts.port == 80 { parts.port = nil }
            url = parts.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = args["method"] as? String ?? "GET"
        let timeout = (args["timeout"] as? Double ?? 0) / 1000
        request.timeoutInterval = timeout > 0 ? timeout : 60
        for (name, value) in args["headers"] as? [String: String] ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        if let body = args["body"] as? String { request.httpBody = Data(body.utf8) }
        if let b64 = args["bodyB64"] as? String { request.httpBody = Data(base64Encoded: b64) }
        if let user = args["user"] as? String {
            let pair = "\(user):\(args["password"] as? String ?? "")"
            request.setValue("Basic " + Data(pair.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        // The tab's own cookies, as a browser's userscript manager sends
        // the browser's, unless the script asks for none.
        let store = (args["anonymous"] as? Bool ?? false) ? nil : webView?.configuration.websiteDataStore.httpCookieStore
        if let store, request.value(forHTTPHeaderField: "Cookie") == nil {
            let host = url.host?.lowercased() ?? ""
            let cookies = await store.allCookies().filter { cookie in
                let domain = cookie.domain.lowercased()
                let domainOK = domain.hasPrefix(".") ? host == domain.dropFirst() || host.hasSuffix(domain) : host == domain
                return domainOK && url.path.hasPrefix(cookie.path) && (!cookie.isSecure || url.scheme == "https")
            }
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        }

        // Headers, then progress, reach the script as they come, in order,
        // and all before the answer.
        let pusher = Pusher { [weak self] message in await self?.push(listener, message) }
        let fetch = Fetch(redirect: args["redirect"] as? String ?? "follow")
        fetch.onResponse = { http in
            let head = Userscripts.describe(http, url)
            Task { @MainActor in pusher.send(head.merging(["type": "xhr", "reqId": reqID, "readyState": 2]) { a, _ in a }) }
        }
        fetch.onData = { loaded, total, http in
            let head = http.map { Userscripts.describe($0, url) } ?? [:]
            Task { @MainActor in
                pusher.progress(head.merging(["type": "xhr", "reqId": reqID, "readyState": 3, "loaded": loaded, "total": total]) { a, _ in a })
            }
        }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: Engine.sessionConfiguration(timeout: request.timeoutInterval), delegate: fetch, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        requests[reqID] = { task.cancel() }
        defer { requests[reqID] = nil }
        let result: Result<(Data, HTTPURLResponse?), Error> = await withCheckedContinuation { done in
            fetch.finish = { done.resume(returning: $0) }
            task.resume()
        }
        await pusher.drain()
        switch result {
        case .success((let data, let response)):
            guard let http = response else { return ["error": "No response"] }
            if let store, let responseURL = http.url {
                let fields = http.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: responseURL) { await store.setCookie(cookie) }
            }
            return Userscripts.describe(http, url).merging(["body": data.base64EncodedString()]) { a, _ in a }
        case .failure(let error):
            if fetch.redirected { return ["error": "Redirected, and the request asked not to follow."] }
            return ["error": error.localizedDescription, "timeout": (error as? URLError)?.code == .timedOut]
        }
    }

    nonisolated static func describe(_ http: HTTPURLResponse, _ asked: URL) -> [String: Any] {
        [
            "status": http.statusCode,
            "statusText": http.statusCode == 200 ? "OK" : HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized,
            "finalUrl": http.url?.absoluteString ?? asked.absoluteString,
            "headers": http.allHeaderFields.map { "\(String(describing: $0.key).lowercased()): \($0.value)" }.sorted().joined(separator: "\r\n"),
        ]
    }

    /// Sends a request's events to the page one after another; progress at
    /// most every 50 ms.
    @MainActor
    private final class Pusher {
        private let deliver: ([String: Any]) async -> Void
        private var chain: Task<Void, Never>?
        private var last = Date.distantPast
        private var held: [String: Any]?
        init(_ deliver: @escaping ([String: Any]) async -> Void) { self.deliver = deliver }

        func send(_ message: [String: Any]) {
            let previous = chain
            chain = Task { await previous?.value; await deliver(message) }
        }

        func progress(_ message: [String: Any]) {
            if Date().timeIntervalSince(last) >= 0.05 { last = Date(); held = nil; send(message) } else { held = message }
        }

        func drain() async {
            if let held { send(held); self.held = nil }
            await chain?.value
        }
    }

    /// One request's delegate, on its own serial queue.
    private final class Fetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let redirect: String
        var onResponse: (HTTPURLResponse) -> Void = { _ in }
        var onData: (Int64, Int64, HTTPURLResponse?) -> Void = { _, _, _ in }
        var finish: (Result<(Data, HTTPURLResponse?), Error>) -> Void = { _ in }
        private(set) var redirected = false
        private var data = Data()
        private var response: HTTPURLResponse?
        private var expected: Int64 = -1

        init(redirect: String) { self.redirect = redirect }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            self.response = response as? HTTPURLResponse
            expected = response.expectedContentLength
            if let http = self.response { onResponse(http) }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            self.data.append(data)
            onData(Int64(self.data.count), expected, response)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            switch redirect {
            case "manual": completionHandler(nil)
            case "error": redirected = true; task.cancel(); completionHandler(nil)
            default: completionHandler(request)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { finish(.failure(error)) } else { finish(.success((data, response))) }
        }
    }
}

extension Userscripts: WKScriptMessageHandlerWithReply {
    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], body["s"] as? String == secret,
              let id = body["id"] as? String, let script = script(id), let op = body["op"] as? String
        else { return (nil, "Not allowed") }
        let args = body["args"] as? [String: Any] ?? [:]
        let grants = script.meta.unwrap ? [] : script.meta.grants
        let webView = message.webView
        let instanceID = body["instance"] as? String ?? ""
        let listener = Listener(instance: Instance(id: instanceID, script: id, frame: message.frameInfo, world: message.world,
                                                   hook: hookBase + id.replacingOccurrences(of: "-", with: "")),
                                webView: webView)
        switch op {
        case "run":
            guard let webView else { return (nil, nil) }
            let page = pages.object(forKey: webView) ?? {
                let page = Page()
                pages.setObject(page, forKey: webView)
                return page
            }()
            page.instances.append(Instance(id: instanceID, script: id, frame: message.frameInfo, world: message.world,
                                           hook: hookBase + id.replacingOccurrences(of: "-", with: "")))
            NotificationCenter.default.post(name: Userscripts.pageChanged, object: webView)
            return (nil, nil)
        case "setValue":
            guard !grants.isDisjoint(with: ["setvalue", "setvalues", "deletevalue", "deletevalues"]),
                  let key = args["key"] as? String else { return (nil, "Not granted") }
            let value = args["value"] as? String
            values[id, default: [:]][key] = value
            revision[id, default: 0] += 1
            writeValues(id)
            broadcast(id, key: key, value: value, from: instanceID)
            return (nil, nil)
        case "xhr":
            guard grants.contains("xmlhttprequest") else { return (nil, "Not granted") }
            return (await request(args, webView: webView, listener: listener), nil)
        case "abort":
            if let reqID = args["reqId"] as? String { requests.removeValue(forKey: reqID)?() }
            return (nil, nil)
        case "menu", "unmenu":
            guard grants.contains(op == "menu" ? "registermenucommand" : "unregistermenucommand"),
                  let webView, let command = args["cmd"] as? String,
                  let instance = pages.object(forKey: webView)?.instances.first(where: { $0.id == instanceID })
            else { return (nil, nil) }
            let page = pages.object(forKey: webView)!
            page.commands.removeAll { $0.instance.id == instanceID && $0.command == command }
            if op == "menu" {
                page.commands.append(MenuCommand(id: "\(instanceID)/\(command)", caption: args["caption"] as? String ?? command,
                                                 script: id, command: command, instance: instance))
            }
            NotificationCenter.default.post(name: Userscripts.pageChanged, object: webView)
            return (nil, nil)
        case "openInTab":
            guard grants.contains("openintab"), let webView, let tab = webView.navigationDelegate as? Tab,
                  let url = (args["url"] as? String).flatMap(URL.init(string:)),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "")
            else { return (nil, "Not granted") }
            guard let opened = tab.delegate?.tab(tab, openScriptTab: url, active: args["active"] as? Bool ?? true) else { return (nil, nil) }
            let key = UUID().uuidString
            openedTabs[key] = (Weak(opened), listener)
            return (key, nil)
        case "closeTab":
            if grants.contains("openintab"), let key = args["tab"] as? String, let opened = openedTabs[key]?.tab.value {
                opened.delegate?.tabWantsToClose(opened)
            }
            return (nil, nil)
        case "closeWindow", "focusWindow":
            guard grants.contains(op == "closeWindow" ? "window.close" : "window.focus"),
                  let webView, let tab = webView.navigationDelegate as? Tab, message.frameInfo.isMainFrame
            else { return (nil, "Not granted") }
            if op == "closeWindow" { tab.delegate?.tabWantsToClose(tab) } else { tab.delegate?.tabWantsFocus(tab) }
            return (nil, nil)
        case "notify":
            guard grants.contains("notification"), let nid = args["nid"] as? String else { return (nil, "Not granted") }
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
                Task { await push(listener, ["type": "notification", "nid": nid, "event": "done"]) }
                return (nil, nil)
            }
            let content = UNMutableNotificationContent()
            content.title = args["title"] as? String ?? script.name
            content.body = args["text"] as? String ?? ""
            content.categoryIdentifier = "userscript"
            if !(args["silent"] as? Bool ?? false) { content.sound = .default }
            if let image = (args["image"] as? String).flatMap(URL.init(string:)),
               let attachment = await Userscripts.attachment(image) {
                content.attachments = [attachment]
            }
            // A tag replaces the script's last notification with that tag.
            let identifier = (args["tag"] as? String).map { "\(id)/tag/\($0)" } ?? "\(id)/\(nid)"
            if let replaced = notifications[identifier], replaced.nid != nid {
                Task { await push(replaced.listener, ["type": "notification", "nid": replaced.nid, "event": "done"]) }
            }
            notifications[identifier] = (nid, listener)
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            if let timeout = args["timeout"] as? Double, timeout > 0 {
                Task {
                    try? await Task.sleep(for: .milliseconds(Int(timeout)))
                    guard notifications[identifier]?.nid == nid else { return }
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                    notificationEnded(identifier, clicked: false)
                }
            }
            return (identifier, nil)
        case "unnotify":
            if let identifier = args["identifier"] as? String, identifier.hasPrefix(id + "/") {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
                notificationEnded(identifier, clicked: false)
            }
            return (nil, nil)
        case "clipboard":
            guard grants.contains("setclipboard"), let data = args["data"] as? String else { return (nil, "Not granted") }
            #if os(macOS)
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(data, forType: (args["type"] as? String ?? "").contains("html") ? .html : .string)
            #endif
            return (nil, nil)
        case "download":
            guard grants.contains("download"), let webView, let tab = webView.navigationDelegate as? Tab,
                  let did = args["did"] as? String, let url = (args["url"] as? String).flatMap(URL.init(string:)),
                  ["https", "http", "blob", "data"].contains(url.scheme?.lowercased() ?? "")
            else { return (nil, "Not granted") }
            var request = URLRequest(url: url)
            for (name, value) in args["headers"] as? [String: String] ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
            let download = await webView.startDownload(using: request)
            downloads[did] = download
            download.delegate = Downloads.shared.adopt(download, for: tab, name: args["name"] as? String) { [weak self] state, received, expected in
                let event: String = switch state {
                case .active: "progress"
                case .finished: "load"
                case .failed: "error"
                case .cancelled: "abort"
                }
                if state != .active { self?.downloads[did] = nil }
                Task { await self?.push(listener, ["type": "download", "did": did, "event": event, "loaded": received, "total": expected]) }
            }
            return (nil, nil)
        case "abortDownload":
            if let did = args["did"] as? String, let download = downloads.removeValue(forKey: did),
               let item = Downloads.shared.items.first(where: { $0.download === download }) {
                Downloads.shared.cancel(item)
            } else if let did = args["did"] as? String {
                downloads.removeValue(forKey: did)?.cancel { _ in }
            }
            return (nil, nil)
        default:
            return (nil, "Unknown")
        }
    }
}

extension Userscripts: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        await MainActor.run { Userscripts.shared.notificationEnded(identifier, clicked: clicked) }
    }

    /// Clicked (onclick, then ondone) or gone (ondone).
    func notificationEnded(_ identifier: String, clicked: Bool) {
        guard let entry = notifications.removeValue(forKey: identifier) else { return }
        Task {
            if clicked { await push(entry.listener, ["type": "notification", "nid": entry.nid, "event": "click"]) }
            await push(entry.listener, ["type": "notification", "nid": entry.nid, "event": "done"])
        }
    }

    /// A notification's picture, fetched into a file of its own.
    static func attachment(_ url: URL) async -> UNNotificationAttachment? {
        let session = Engine.session(timeout: 15)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, mime) = try? await fetch(url, in: session) else { return nil }
        let type = mime.split(separator: "/").last.map(String.init) ?? "png"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (type == "jpeg" ? "jpg" : type))
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: UUID().uuidString, url: file)
    }
}

#if os(macOS)
extension Userscripts {
    /// Violentmonkey's backup (its exported .zip: the scripts, each one's
    /// switch, whether it updates, and its values), or .user.js files.
    /// Each script's @require and @resource files are fetched again.
    public func importFiles(_ files: [URL]) async -> (count: Int, problems: [String]) {
        var count = 0
        var problems: [String] = []
        for file in files {
            guard file.pathExtension.lowercased() == "zip" else {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { problems.append("\(file.lastPathComponent): can't be read"); continue }
                if let problem = await importScript(text, entry: nil, values: nil) { problems.append("\(file.lastPathComponent): \(problem)") } else { count += 1 }
                continue
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("userscripts-import-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", file.path, folder.path]
            let finished: Bool = await withCheckedContinuation { done in
                unzip.terminationHandler = { done.resume(returning: $0.terminationStatus == 0) }
                do { try unzip.run() } catch { unzip.terminationHandler = nil; done.resume(returning: false) }
            }
            guard finished else { problems.append("\(file.lastPathComponent): not a zip that can be opened"); continue }
            let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            let manifest = found.first { $0.lastPathComponent == "violentmonkey" }
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let entries = manifest?["scripts"] as? [String: Any] ?? [:]
            let values = manifest?["values"] as? [String: Any] ?? [:]
            let sources = found.filter { $0.lastPathComponent.hasSuffix(".user.js") }.sorted {
                ((entries[Userscripts.base($0)] as? [String: Any])?["position"] as? Int ?? 0) < ((entries[Userscripts.base($1)] as? [String: Any])?["position"] as? Int ?? 0)
            }
            if sources.isEmpty { problems.append("\(file.lastPathComponent): no userscripts in it") }
            for source in sources {
                guard let text = try? String(contentsOf: source, encoding: .utf8) else { continue }
                if let problem = await importScript(text, entry: entries[Userscripts.base(source)] as? [String: Any], values: values) {
                    problems.append("\(source.lastPathComponent): \(problem)")
                } else {
                    count += 1
                }
            }
        }
        return (count, problems)
    }

    private static func base(_ file: URL) -> String { String(file.lastPathComponent.dropLast(".user.js".count)) }

    /// Nil when it went in.
    private func importScript(_ source: String, entry: [String: Any]?, values backup: [String: Any]?) async -> String? {
        let custom = entry?["custom"] as? [String: Any]
        let config = entry?["config"] as? [String: Any]
        let from = (custom?["lastInstallURL"] as? String).flatMap(URL.init(string:))
        do {
            var script = try await install(source, from: from)
            script.enabled = (config?["enabled"] as? NSNumber)?.boolValue ?? true
            // Violentmonkey's "allow updates" off: kept as it is, like an edited script.
            script.edited = !((config?["shouldUpdate"] as? NSNumber)?.boolValue ?? true)
            put(script)
            let meta = script.meta
            let props = entry?["props"] as? [String: Any]
            let uris = [props?["uri"] as? String, "\(Userscripts.jsEscape(meta.namespace)):\(Userscripts.jsEscape(meta.name)):"].compactMap { $0 }
            if let stored = uris.lazy.compactMap({ backup?[$0] as? [String: Any] }).first {
                var imported: [String: String] = [:]
                for (key, raw) in stored { if let value = Userscripts.importedValue(raw) { imported[key] = value } }
                values[script.id] = imported
                revision[script.id, default: 0] += 1
                flushValues(script.id)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// JavaScript's `escape()`, which Violentmonkey keys values by.
    static func jsEscape(_ text: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@*_+-./".utf16)
        return text.utf16.map { unit in
            if safe.contains(unit) { return String(UnicodeScalar(UInt8(unit))) }
            return unit < 256 ? String(format: "%%%02X", unit) : String(format: "%%u%04X", unit)
        }.joined()
    }

    /// A stored value as JSON: Violentmonkey's older backups prefix each
    /// with its type (`s` string, `n` number, `b` boolean, `o` object).
    static func importedValue(_ raw: Any) -> String? {
        let isJSON = { (text: String) in (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil }
        guard let text = raw as? String else {
            return (try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) }
        }
        if isJSON(text) { return text }
        let rest = String(text.dropFirst())
        switch text.first {
        case "n", "b", "o": return isJSON(rest) ? rest : quote(text)
        case "s": return quote(rest)
        default: return quote(text)
        }
    }
}
#endif

extension Userscripts {
    /// Runs in the page before anything else, once per script. Takes the
    /// script's function and its settings; checks the address, builds the
    /// GM APIs it was granted, and runs it at its @run-at.
    static let bootstrap = #"""
    function (run, C) {
      'use strict';
      const W = window, D = document;
      if (!/^(?:https?|file):$/.test(location.protocol)) return;
      const href = location.href;
      const test = r => { try { return new RegExp(r[0], r[1]).test(href); } catch (e) { return false; } };
      if (!(C.everywhere || C.include.some(test)) || C.exclude.some(test)) return;
      if (C.noframes && W.top !== W) return;
      if (C.framesOnly && W.top === W) return;
      const handlers = W.webkit && W.webkit.messageHandlers;
      const handler = handlers && handlers[C.handler];
      const post = handler ? handler.postMessage.bind(handler) : null;
      const define = Object.defineProperty, keys = Object.keys, apply = Reflect.apply, then = Promise.prototype.then;
      const Proxy_ = Proxy, get = Reflect.get, set = Reflect.set, has = Object.prototype.hasOwnProperty;
      const rand = () => Math.random().toString(36).slice(2);
      const listen = EventTarget.prototype.addEventListener, parse = JSON.parse, stringify = JSON.stringify;
      const URL_ = URL, Blob_ = Blob, TextDecoder_ = TextDecoder, DOMParser_ = DOMParser, atob_ = atob, btoa_ = btoa;
      const timeout = setTimeout, error = console.error.bind(console), log = console.log.bind(console);
      const instance = Math.random().toString(36).slice(2);
      const send = (op, args) => post
        ? post({s: C.secret, id: C.id, instance, op, args: args === undefined ? null : args})
        : Promise.reject(new Error('Userscripts are unavailable here'));
      const quiet = p => { apply(then, p, [undefined, () => {}]); return p; };
      const name = C.info.script.name;
      const report = e => error('[' + name + ']', e);
      const resolve = url => new URL_(url, href).href;

      const values = Object.create(null);
      for (const [k, v] of C.values) values[k] = v;
      const listeners = new Map();
      let nextListener = 1;
      const notify = (key, oldRaw, newRaw, remote) => {
        const decode = raw => { if (raw == null) return undefined; try { return parse(raw); } catch (e) { return undefined; } };
        listeners.forEach(l => { if (l.key === key) try { l.cb(key, decode(oldRaw), decode(newRaw), remote); } catch (e) { report(e); } });
      };
      const getValue = (key, def) => {
        const raw = values[String(key)];
        if (raw === undefined) return def;
        try { return parse(raw); } catch (e) { return def; }
      };
      const deleteValue = key => {
        key = String(key);
        const old = values[key];
        if (old === undefined) return Promise.resolve();
        delete values[key];
        notify(key, old, null, false);
        return quiet(send('setValue', {key, value: null}));
      };
      const setValue = (key, value) => {
        key = String(key);
        if (value === undefined) return deleteValue(key);
        const raw = stringify(value), old = values[key];
        values[key] = raw;
        if (old !== raw) notify(key, old, raw, false);
        return quiet(send('setValue', {key, value: raw}));
      };
      const listValues = () => keys(values);
      const getValues = arg => {
        const out = {};
        if (Array.isArray(arg)) { for (const k of arg) { const v = getValue(k); if (v !== undefined) out[k] = v; } }
        else for (const k of keys(arg || {})) out[k] = getValue(k, arg[k]);
        return out;
      };
      const setValues = obj => { for (const k of keys(obj || {})) setValue(k, obj[k]); return Promise.resolve(); };
      const deleteValues = list => { for (const k of list || []) deleteValue(k); return Promise.resolve(); };
      const addValueChangeListener = (key, cb) => { const id = nextListener++; listeners.set(id, {key: String(key), cb}); return id; };
      const removeValueChangeListener = id => { listeners.delete(id); };

      const resources = Object.create(null);
      for (const [n, mime, data] of C.resources) resources[n] = {mime, data};
      const bytes = b64 => { const s = atob_(b64); const a = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) a[i] = s.charCodeAt(i); return a; };
      const base64 = buffer => {
        const a = new Uint8Array(buffer); let s = '';
        for (let i = 0; i < a.length; i += 0x8000) s += String.fromCharCode.apply(null, a.subarray(i, i + 0x8000));
        return btoa_(s);
      };
      const getResourceText = n => { const r = resources[n]; return r ? new TextDecoder_().decode(bytes(r.data)) : undefined; };
      const blobs = Object.create(null);
      const getResourceURL = (n, blob) => {
        const r = resources[n];
        if (!r) return undefined;
        if (blob === false) return 'data:' + r.mime + ';base64,' + r.data;
        return blobs[n] || (blobs[n] = URL_.createObjectURL(new Blob_([bytes(r.data)], {type: r.mime})));
      };

      const root = () => D.head || D.documentElement || D;
      const addElement = (parent, tag, attrs) => {
        if (typeof parent === 'string') { attrs = tag; tag = parent; parent = null; }
        const el = D.createElement(tag);
        for (const k of keys(attrs || {})) { if (k === 'textContent') el.textContent = attrs[k]; else el.setAttribute(k, attrs[k]); }
        (parent || (/^(?:script|style|link|meta)$/i.test(tag) ? root() : (D.body || root()))).appendChild(el);
        return el;
      };
      const addStyle = css => addElement('style', {textContent: String(css)});

      const charset = type => { const m = /charset=([^;]+)/i.exec(type || ''); return m ? m[1].trim().replace(/^"|"$/g, '') : 'utf-8'; };
      const encodeBody = async data => {
        if (data == null) return {};
        if (typeof data === 'string') return {body: data};
        if (data instanceof URLSearchParams) return {body: data.toString(), type: 'application/x-www-form-urlencoded;charset=UTF-8'};
        if (data instanceof Blob_) return {bodyB64: base64(await data.arrayBuffer()), type: data.type || undefined};
        if (data instanceof ArrayBuffer) return {bodyB64: base64(data)};
        if (ArrayBuffer.isView(data)) return {bodyB64: base64(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength))};
        if (data instanceof FormData) { const r = new Response(data); return {bodyB64: base64(await r.arrayBuffer()), type: r.headers.get('content-type')}; }
        if (data instanceof Document) return {body: new XMLSerializer().serializeToString(data)};
        return {body: String(data)};
      };
      const live = Object.create(null);
      const xhr = details => {
        const d = details || {};
        let aborted = false, done = false;
        const reqId = rand();
        const fire = (event, r) => { const f = d[event]; if (typeof f === 'function') try { apply(f, r, [r]); } catch (e) { report(e); } };
        const response = (n, data) => {
          let text, body, decoded = false;
          const type = d.overrideMimeType || (/^content-type:\s*(.*)$/im.exec(n.headers || '') || [])[1] || '';
          const raw = () => data || new Uint8Array(0);
          const getText = () => {
            if (text === undefined) { try { text = new TextDecoder_(charset(type)).decode(raw()); } catch (e) { text = new TextDecoder_().decode(raw()); } }
            return text;
          };
          const loaded = n.loaded != null ? n.loaded : (data ? data.length : 0);
          const total = n.total != null && n.total >= 0 ? n.total : (data ? data.length : 0);
          const r = {
            readyState: n.readyState == null ? 4 : n.readyState, status: n.status || 0, statusText: n.statusText || '',
            finalUrl: n.finalUrl || '', responseHeaders: n.headers || '', context: d.context,
            lengthComputable: total > 0, loaded, total,
          };
          define(r, 'responseText', {get: getText, enumerable: true});
          define(r, 'response', {enumerable: true, get() {
            if (decoded) return body;
            decoded = true;
            const t = String(d.responseType || '').toLowerCase();
            const mime = type.split(';')[0].trim();
            if (t === 'json') { try { body = parse(getText()); } catch (e) { body = null; } }
            else if (t === 'arraybuffer') body = raw().buffer;
            else if (t === 'blob') body = new Blob_([raw()], {type: mime});
            else if (t === 'document') body = new DOMParser_().parseFromString(getText(), /xml/.test(mime) ? mime : 'text/html');
            else body = getText();
            return body;
          }});
          define(r, 'responseXML', {enumerable: true, get() {
            try { return new DOMParser_().parseFromString(getText(), /xml/.test(type) ? 'text/xml' : 'text/html'); } catch (e) { return null; }
          }});
          return r;
        };
        live[reqId] = n => {
          if (done || aborted) return;
          const r = response(n);
          fire('onreadystatechange', r);
          if (n.readyState === 3) fire('onprogress', r);
        };
        const control = {
          abort() {
            if (done || aborted) return;
            aborted = true;
            delete live[reqId];
            quiet(send('abort', {reqId}));
            const r = response({status: 0});
            fire('onabort', r);
            fire('onloadend', r);
          },
        };
        (async () => {
          let url;
          try { url = resolve(d.url); } catch (e) {
            done = true;
            const r = response({statusText: String(e)});
            fire('onerror', r); fire('onloadend', r);
            return;
          }
          const encoded = await encodeBody(d.data);
          if (aborted) return;
          const headers = {};
          for (const k of keys(d.headers || {})) headers[k] = String(d.headers[k]);
          if (encoded.type && !keys(headers).some(k => k.toLowerCase() === 'content-type')) headers['Content-Type'] = encoded.type;
          fire('onloadstart', response({readyState: 1, finalUrl: url}));
          let n;
          try {
            n = await send('xhr', {
              reqId, url, method: String(d.method || 'GET').toUpperCase(), headers,
              body: encoded.body == null ? null : encoded.body, bodyB64: encoded.bodyB64 || null,
              timeout: +d.timeout || 0, anonymous: !!d.anonymous, user: d.user || null, password: d.password || null,
              redirect: d.redirect || 'follow',
            });
          } catch (e) { n = {error: String(e && e.message || e)}; }
          delete live[reqId];
          if (aborted) return;
          done = true;
          if (n.error) {
            const r = response({statusText: n.error, finalUrl: url});
            fire(n.timeout ? 'ontimeout' : 'onerror', r); fire('onloadend', r);
            return;
          }
          const r = response(n, bytes(n.body || ''));
          fire('onprogress', r); fire('onreadystatechange', r); fire('onload', r); fire('onloadend', r);
        })();
        return control;
      };
      const xhrPromise = details => {
        const d = details || {};
        let control;
        const p = new Promise((ok, fail) => {
          const wrap = (event, settle) => r => { if (typeof d[event] === 'function') try { d[event](r); } catch (e) { report(e); } settle(r); };
          control = xhr(Object.assign({}, d, {onload: wrap('onload', ok), onerror: wrap('onerror', fail), ontimeout: wrap('ontimeout', fail), onabort: wrap('onabort', fail)}));
        });
        p.abort = () => control.abort();
        return p;
      };

      const commands = Object.create(null);
      const registerMenuCommand = (caption, cb, opts) => {
        const o = opts && typeof opts === 'object' ? opts : {};
        const id = o.id != null ? String(o.id) : String(caption);
        commands[id] = cb;
        quiet(send('menu', {cmd: id, caption: String(caption)}));
        return id;
      };
      const unregisterMenuCommand = id => { delete commands[String(id)]; quiet(send('unmenu', {cmd: String(id)})); };

      const tabs = Object.create(null);
      const openInTab = (url, opts) => {
        const o = opts && typeof opts === 'object' ? opts : {active: opts === undefined ? true : !opts};
        const active = o.active !== undefined ? !!o.active : !o.loadInBackground;
        let tab = null, closing = false;
        const handle = {closed: false, onclose: null, close() { closing = true; if (tab) quiet(send('closeTab', {tab})); }};
        apply(then, send('openInTab', {url: resolve(url), active}), [id => {
          if (!id) return;
          tab = id;
          tabs[id] = handle;
          if (closing) quiet(send('closeTab', {tab}));
        }, report]);
        return handle;
      };

      const notes = Object.create(null);
      const notification = (text, title, image, onclick) => {
        const o = text && typeof text === 'object' ? text : {text, title, image, onclick};
        const nid = rand();
        let identifier = null, removed = false;
        notes[nid] = o;
        apply(then, send('notify', {
          nid, text: String(o.text || ''), title: String(o.title || name), image: o.image ? resolve(o.image) : null,
          silent: !!o.silent, tag: o.tag != null ? String(o.tag) : null, timeout: +o.timeout || 0,
        }), [id => { identifier = id; if (removed && id) quiet(send('unnotify', {identifier: id})); }, report]);
        return {remove: () => { removed = true; return identifier ? quiet(send('unnotify', {identifier})) : Promise.resolve(); }};
      };
      const setClipboard = (data, info) => {
        const type = typeof info === 'string' ? info : (info && (info.mimetype || info.type)) || 'text/plain';
        return quiet(send('clipboard', {data: String(data), type}));
      };

      const saving = Object.create(null);
      const download = (url, n) => {
        const o = url && typeof url === 'object' ? url : {url, name: n};
        const did = rand();
        const call = (event, arg) => { const f = o[event]; if (typeof f === 'function') try { f(arg); } catch (e) { report(e); } };
        let ok, fail;
        const p = new Promise((a, b) => { ok = a; fail = b; });
        apply(then, p, [undefined, () => {}]);
        saving[did] = m => {
          const progress = {loaded: m.loaded, total: m.total, lengthComputable: m.total > 0};
          if (m.event === 'progress') return call('onprogress', progress);
          delete saving[did];
          if (m.event === 'load') { call('onload', progress); ok(); return; }
          const e = {error: m.event === 'abort' ? 'aborted' : (m.error || 'failed'), details: m.error || ''};
          call(m.event === 'abort' ? 'onabort' : 'onerror', e);
          fail(e);
        };
        let target;
        try { target = resolve(o.url); } catch (e) { saving[did]({event: 'error', error: String(e)}); return p; }
        const headers = {};
        for (const k of keys(o.headers || {})) headers[k] = String(o.headers[k]);
        apply(then, send('download', {did, url: target, name: o.name || null, headers}), [undefined, e => {
          if (saving[did]) saving[did]({event: 'error', error: String(e && e.message || e)});
        }]);
        p.abort = () => { if (saving[did]) quiet(send('abortDownload', {did})); };
        return p;
      };

      const promised = f => (...a) => { try { return Promise.resolve(f(...a)); } catch (e) { return Promise.reject(e); } };
      const table = {
        getvalue: [getValue, ['getValue', promised(getValue)]],
        setvalue: [(k, v) => { setValue(k, v); }, ['setValue', setValue]],
        deletevalue: [k => { deleteValue(k); }, ['deleteValue', deleteValue]],
        listvalues: [listValues, ['listValues', promised(listValues)]],
        getvalues: [getValues, ['getValues', promised(getValues)]],
        setvalues: [o => { setValues(o); }, ['setValues', setValues]],
        deletevalues: [k => { deleteValues(k); }, ['deleteValues', deleteValues]],
        addvaluechangelistener: [addValueChangeListener, ['addValueChangeListener', promised(addValueChangeListener)]],
        removevaluechangelistener: [removeValueChangeListener, ['removeValueChangeListener', promised(removeValueChangeListener)]],
        getresourcetext: [getResourceText, ['getResourceText', promised(getResourceText)]],
        getresourceurl: [getResourceURL, ['getResourceUrl', promised(getResourceURL)], ['getResourceURL', promised(getResourceURL)]],
        addstyle: [addStyle, ['addStyle', promised(addStyle)]],
        addelement: [addElement, ['addElement', promised(addElement)]],
        openintab: [openInTab, ['openInTab', promised(openInTab)]],
        registermenucommand: [registerMenuCommand, ['registerMenuCommand', promised(registerMenuCommand)]],
        unregistermenucommand: [unregisterMenuCommand, ['unregisterMenuCommand', promised(unregisterMenuCommand)]],
        notification: [notification, ['notification', promised(notification)]],
        setclipboard: [setClipboard, ['setClipboard', setClipboard]],
        xmlhttprequest: [xhr, ['xmlHttpRequest', xhrPromise]],
        download: [download, ['download', download]],
        log: [log, ['log', promised(log)]],
      };
      const legacy = {
        getvalue: 'GM_getValue', setvalue: 'GM_setValue', deletevalue: 'GM_deleteValue', listvalues: 'GM_listValues',
        getvalues: 'GM_getValues', setvalues: 'GM_setValues', deletevalues: 'GM_deleteValues',
        addvaluechangelistener: 'GM_addValueChangeListener', removevaluechangelistener: 'GM_removeValueChangeListener',
        getresourcetext: 'GM_getResourceText', getresourceurl: 'GM_getResourceURL', addstyle: 'GM_addStyle',
        addelement: 'GM_addElement', openintab: 'GM_openInTab', registermenucommand: 'GM_registerMenuCommand',
        unregistermenucommand: 'GM_unregisterMenuCommand', notification: 'GM_notification', setclipboard: 'GM_setClipboard',
        xmlhttprequest: 'GM_xmlhttpRequest', download: 'GM_download', log: 'GM_log',
      };
      const info = C.info;
      const gm = {info};
      const api = {GM_info: info, GM: gm, unsafeWindow: W};
      for (const g of C.grants) {
        const t = table[g];
        if (!t) continue;
        api[legacy[g]] = t[0];
        for (let i = 1; i < t.length; i++) gm[t[i][0]] = t[i][1];
      }
      if (C.params.includes('window')) {
        // The script's own `window`: the page's, with close and focus that
        // reach its tab. Page methods are called on the real window.
        const own = Object.create(null);
        if (C.grants.includes('window.close')) own.close = () => { quiet(send('closeWindow')); };
        if (C.grants.includes('window.focus')) own.focus = () => { quiet(send('focusWindow')); };
        const bound = new WeakMap();
        api.window = new Proxy_(W, {
          get(target, key) {
            if (apply(has, own, [key])) return own[key];
            const value = get(target, key);
            if (typeof value !== 'function' || 'prototype' in value) return value;
            let b = bound.get(value);
            if (!b) { b = value.bind(target); bound.set(value, b); }
            return b;
          },
          set(target, key, value) { return set(target, key, value); },
        });
      }
      const args = C.params.map(p => api[p]);

      define(W, C.hook, {configurable: false, enumerable: false, writable: false, value: msg => {
        if (!msg) return;
        if (msg.type === 'value') {
          const old = values[msg.key];
          if (msg.value == null) delete values[msg.key]; else values[msg.key] = msg.value;
          if (old !== msg.value) notify(msg.key, old, msg.value, true);
        } else if (msg.type === 'xhr') {
          const f = live[msg.reqId];
          if (f) f(msg);
        } else if (msg.type === 'download') {
          const f = saving[msg.did];
          if (f) f(msg);
        } else if (msg.type === 'tabclosed') {
          const t = tabs[msg.tab];
          if (t) {
            delete tabs[msg.tab];
            t.closed = true;
            if (typeof t.onclose === 'function') try { t.onclose(); } catch (e) { report(e); }
          }
        } else if (msg.type === 'notification') {
          const o = notes[msg.nid];
          if (o) {
            if (msg.event === 'click' && typeof o.onclick === 'function') try { o.onclick(); } catch (e) { report(e); }
            if (msg.event === 'done') {
              delete notes[msg.nid];
              if (typeof o.ondone === 'function') try { o.ondone(); } catch (e) { report(e); }
            }
          }
        } else if (msg.type === 'menu') {
          const cb = commands[msg.cmd];
          if (typeof cb === 'function') try { cb(new MouseEvent('click')); } catch (e) { report(e); }
        }
      }});

      const go = () => {
        quiet(send('run', {top: W.top === W}));
        try {
          const r = apply(run, W, args);
          if (r && typeof r.then === 'function') apply(then, r, [undefined, report]);
        } catch (e) { report(e); }
      };
      const at = C.runAt;
      if (at === 'document-start') go();
      else if (at === 'document-body') {
        if (D.body) go();
        else {
          const watch = new MutationObserver(() => { if (D.body) { watch.disconnect(); go(); } });
          watch.observe(D.documentElement || D, {childList: true, subtree: true});
        }
      } else {
        const ready = () => { if (at === 'document-idle') timeout(go, 0); else go(); };
        if (D.readyState === 'loading') apply(listen, D, ['DOMContentLoaded', ready, {once: true}]); else ready();
      }
    }
    """#
}
