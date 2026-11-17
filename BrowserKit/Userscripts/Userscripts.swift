import Foundation
import Observation
import WebKit

// STUB: the public surface the shells and the rest of BrowserKit rely on.
// The bodies are to be rebuilt; the signatures here are the contract.

/// An installed userscript: its source as written, and what it fetched
/// when it was installed (@require and @resource).
public struct Userscript: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var source: String
    public var enabled = true
    public var installURL: String?
    /// Changed here since it was installed: updates leave it alone.
    public var edited = false

    public var meta: UserscriptMeta { UserscriptMeta.parse(source) ?? UserscriptMeta() }
    public var name: String { meta.name.isEmpty ? "Untitled" : meta.name }
}

public struct UserscriptMeta: Equatable, Sendable {
    public var name = ""
    public var namespace = ""
    public var version = ""
    public var description = ""
    public init() {}

    public static func parse(_ source: String) -> UserscriptMeta? { nil }
    /// The sites it runs on, for a line under its name: `youtube.com,
    /// github.com`, or "every site".
    public var sites: String { "" }
    /// Violentmonkey's comparison: dotted parts, numbers as numbers.
    public static func newer(_ a: String, than b: String) -> Bool { false }
}

public struct UserscriptError: LocalizedError {
    public let errorDescription: String?
}

@MainActor @Observable
public final class Userscripts: NSObject {
    public static let shared = Userscripts()

    public private(set) var scripts: [Userscript] = []

    /// A command a running script registered with GM_registerMenuCommand.
    public struct MenuCommand: Identifiable {
        public let id: String
        public let caption: String
        /// The id of the script that registered it.
        public let script: String
    }

    /// A script that applies to a page: whether it is running there now,
    /// and the commands it registered.
    public struct OnPage: Identifiable {
        public let script: Userscript
        public let running: Bool
        public let commands: [MenuCommand]
        public var id: String { script.id }
    }

    /// Loads the installed scripts and keeps them updated: once at launch.
    public func start() {}
    /// Values still waiting to be written, written now: Browser is quitting.
    public func flush() {}

    public func script(_ id: String) -> Userscript? { nil }
    /// A script's stored values (GM_setValue), each as JSON.
    public func values(of id: String) -> [String: String] { [:] }

    /// Installs a script, or replaces the one with the same @name and
    /// @namespace (keeping its values and its switch). Fetches its
    /// @require and @resource files first.
    @discardableResult
    public func install(_ source: String, from url: URL?) async throws -> Userscript { throw UserscriptError(errorDescription: "") }
    /// The installed script with the same @name and @namespace as `source`.
    public func installed(like source: String) -> Userscript? { nil }
    /// The editor's ⌘S: a script edited here.
    public func save(_ id: String, source: String) async throws {}
    /// A new script with a template to fill in.
    public func create() -> Userscript { Userscript(id: "", source: "") }
    public func setEnabled(_ id: String, _ on: Bool) {}
    public func remove(_ id: String) {}
    /// Why JavaScriptCore can't parse `source`, or nil if it can.
    public static func syntaxError(_ source: String, _ meta: UserscriptMeta?) -> String? { nil }
    /// Violentmonkey's backup (.zip) or .user.js files.
    public func importFiles(_ files: [URL]) async -> (count: Int, problems: [String]) { (0, []) }
    public func checkForUpdates() async {}

    /// The scripts for the page in `webView`, on or off. Observable: a view
    /// reading it is told when a page's scripts or their commands change.
    public func scripts(on webView: WKWebView?) -> [OnPage] { [] }
    public func perform(_ command: MenuCommand, in webView: WKWebView) {}

    func prepare(_ controller: WKUserContentController, for url: URL?, mainFrame: Bool) {}
    func pageChanged(_ webView: WKWebView) {}
    func tabClosed(_ tab: Tab) {}
}
