import Foundation
import Observation
import WebKit

/// Browser's userscript runner, compatible with Violentmonkey's scripts and
/// its GM_* and GM.* APIs.
///
/// This is the list of installed scripts, and everything done to it:
/// installing, editing, switching and removing. Running them is in the
/// parts it holds: `UserscriptInjection` puts each page's scripts into it,
/// `UserscriptRuntime` is what runs them there, and the GM APIs reach the
/// app through `UserscriptBridge`.
@MainActor @Observable
public final class Userscripts: NSObject {
    public static let shared = Userscripts()

    public private(set) var scripts: [Userscript] = []

    /// Where each script runs, worked out when it is installed or changed
    /// rather than at every navigation.
    @ObservationIgnored private var rules: [String: UserscriptRules] = [:]
    private let values: UserscriptValues
    private let pages: UserscriptPages
    private let bridge: UserscriptBridge
    private let injection: UserscriptInjection

    private override init() {
        let values = UserscriptValues(), pages = UserscriptPages()
        let bridge = UserscriptBridge(values: values, pages: pages) { Userscripts.shared.script($0) }
        self.values = values
        self.pages = pages
        self.bridge = bridge
        injection = UserscriptInjection(bridge: bridge, values: values)
        super.init()
        scripts = UserscriptStore.scripts()
        values.load(for: scripts)
        for script in scripts { rules[script.id] = UserscriptRules(script.meta) }
    }

    /// Keeps the installed scripts updated, and hears what becomes of
    /// their notifications: once at launch.
    public func start() {
        bridge.notifications.start()
        checkForUpdatesDaily()
    }

    /// Values still waiting to be written, written now: Browser is quitting.
    public func flush() {
        values.flush()
    }

    public func script(_ id: String) -> Userscript? {
        scripts.first { $0.id == id }
    }

    /// A script's stored values (GM_setValue), each as JSON.
    public func values(of id: String) -> [String: String] {
        values.values(of: id)
    }

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
        let fetched = try await UserscriptDependencies.fetch(for: meta, relativeTo: url)
        var script = installed(like: source) ?? .new(source)
        script.source = source
        script.installURL = url?.absoluteString ?? script.installURL
        script.edited = false
        script.requires = fetched.requires
        script.resources = fetched.resources
        script.updated = Date()
        put(script)
        return script
    }

    /// The installed script with the same @name and @namespace as `source`.
    public func installed(like source: String) -> Userscript? {
        guard let meta = UserscriptMeta.parse(source), !meta.name.isEmpty else { return nil }
        return scripts.first { $0.meta.name == meta.name && $0.meta.namespace == meta.namespace }
    }

    /// The editor's ⌘S: a script edited here. One that doesn't parse isn't
    /// saved. The @require and @resource files it already has are kept;
    /// only new ones are fetched.
    public func save(_ id: String, source: String) async throws {
        guard let installed = script(id) else { return }
        guard let meta = UserscriptMeta.parse(source) else {
            throw UserscriptError("A script needs its ==UserScript== block.")
        }
        if let error = Userscripts.syntaxError(source, meta) { throw UserscriptError(error) }
        let fetched = try await UserscriptDependencies.fetch(for: meta, relativeTo: installed.installURL.flatMap(URL.init(string:)), keeping: installed)
        // Removed while fetching: it stays removed.
        guard var script = script(id) else { return }
        script.source = source
        script.edited = true
        script.requires = fetched.requires
        script.resources = fetched.resources
        script.updated = Date()
        put(script)
    }

    /// A new script with a template to fill in.
    @discardableResult
    public func create() -> Userscript {
        var name = "New Script"
        var number = 2
        while scripts.contains(where: { $0.meta.name == name }) {
            name = "New Script \(number)"
            number += 1
        }
        var script = Userscript.new("""
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
        scripts.removeAll { $0.id == id }
        rules[id] = nil
        values.remove(id)
        UserscriptStore.remove(id)
        injection.changed(id)
    }

    /// Why JavaScriptCore can't parse `source`, or nil if it can.
    public static func syntaxError(_ source: String, _ meta: UserscriptMeta?) -> String? {
        UserscriptSyntax.error(in: source, topLevelAwait: meta?.topLevelAwait == true)
    }

    /// Keeps a new or changed script, in memory and on disk. It reaches a
    /// page at its next load: nothing reloads, since a reload wipes.
    func put(_ script: Userscript) {
        if let index = scripts.firstIndex(where: { $0.id == script.id }) { scripts[index] = script } else { scripts.append(script) }
        rules[script.id] = UserscriptRules(script.meta)
        UserscriptStore.write(script)
        injection.changed(script.id)
    }

    /// A script's values as a backup has them, in place of its own.
    func setValues(_ imported: [String: String], of id: String) {
        values.replace(imported, of: id)
    }

    // MARK: Pages

    /// The scripts for the page in `webView`, on or off: each that matches
    /// its address or is running in it, and the menu commands of those
    /// running. Observable: a view reading it is told when a page's scripts
    /// or their commands change.
    public func scripts(on webView: WKWebView?) -> [OnPage] {
        guard let webView else { return [] }
        let page = pages.page(in: webView)
        // Read so that whoever is watching hears of the next page too,
        // whether or not a script runs on it.
        _ = page.documents
        guard let address = webView.url?.absoluteString else { return [] }
        let running = Set(page.instances.map(\.script))
        return scripts.compactMap { script in
            let runs = running.contains(script.id)
            guard runs || rules[script.id]?.matches(address) == true else { return nil }
            return OnPage(script: script, running: runs, commands: page.commands.filter { $0.script == script.id })
        }
    }

    /// Runs a menu command in the copy of the script that registered it,
    /// if `webView` still shows the page it registered it on.
    public func perform(_ command: MenuCommand, in webView: WKWebView) {
        guard command.instance.webView === webView else { return }
        Task { await command.instance.push(["type": "menu", "cmd": command.command]) }
    }

    /// As a frame's navigation is decided: the scripts for `url` go into
    /// the web view `controller` belongs to.
    func prepare(_ controller: WKUserContentController, for url: URL?, mainFrame: Bool) {
        guard !scripts.isEmpty, let url, let scheme = url.scheme?.lowercased(), ["https", "http", "file"].contains(scheme) else { return }
        injection.prepare(controller, for: url.absoluteString, mainFrame: mainFrame, scripts: scripts, rules: rules)
    }

    /// A new document in `webView`'s main frame: what ran before has gone.
    func pageChanged(_ webView: WKWebView) {
        pages.changed(in: webView)
    }

    /// The scripts that opened `tab` with GM_openInTab hear that it closed.
    func tabClosed(_ tab: Tab) {
        bridge.tabs.closed(tab)
    }
}
