import WebKit

/// A message from a running script, once the bridge has checked its secret.
struct UserscriptCall {
    let script: Userscript
    /// What the script may ask for: its @grants, read again here rather
    /// than taken on the page's word.
    let grants: Set<String>
    let arguments: [String: Any]
    /// The copy of the script that sent it.
    let instance: UserscriptInstance

    var webView: WKWebView? { instance.webView }

    func string(_ name: String) -> String? { arguments[name] as? String }

    /// The address under `name`, if its scheme is one of `schemes`.
    func url(_ name: String, schemes: Set<String>) -> URL? {
        guard let url = string(name).flatMap(URL.init(string:)), schemes.contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

/// Why the bridge didn't do what a message asked: what the page's promise
/// is rejected with.
enum UserscriptRefusal: String, Error {
    case notAllowed = "Not allowed"
    case notGranted = "Not granted"
    case unknown = "Unknown"
}

/// How the GM APIs reach the app: one message handler, there only where a
/// script runs.
///
/// A page can see that handler where a script runs in its world, so every
/// message carries a secret made at launch that only the scripts hold; a
/// message without it does nothing. A script gets only the APIs it @grants,
/// and each API checks the grant again here.
@MainActor
final class UserscriptBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "browserUserscripts"
    /// Browser's own world, for `@inject-into content`.
    static let world = WKContentWorld.world(name: "Userscripts")

    let secret = UserscriptBridge.random(32)
    private let hookPrefix = "__bu" + UserscriptBridge.random(12)

    let tabs = GMTabs()
    let notifications = GMNotifications()
    private let values: GMValues
    private let menuCommands: GMMenuCommands
    private let requests = GMRequests()
    private let downloads = GMDownloads()
    private let pages: UserscriptPages
    private let script: (String) -> Userscript?

    /// `script`: the installed script with an id.
    init(values: UserscriptValues, pages: UserscriptPages, script: @escaping (String) -> Userscript?) {
        self.values = GMValues(values, pages: pages)
        menuCommands = GMMenuCommands(pages)
        self.pages = pages
        self.script = script
    }

    private static func random(_ count: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0 ..< count).map { _ in characters[Int.random(in: 0 ..< characters.count)] })
    }

    /// The name of the function a script's copies leave on their `window`
    /// to be told things by: one no page can guess.
    func hook(for script: String) -> String {
        hookPrefix + script.replacingOccurrences(of: "-", with: "")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], body["s"] as? String == secret,
              let id = body["id"] as? String, let script = script(id), let operation = body["op"] as? String
        else { return (nil, UserscriptRefusal.notAllowed.rawValue) }
        let instance = UserscriptInstance(id: body["instance"] as? String ?? "", script: id, webView: message.webView,
                                          frame: message.frameInfo, world: message.world, hook: hook(for: id))
        let call = UserscriptCall(script: script, grants: script.meta.grants, arguments: body["args"] as? [String: Any] ?? [:], instance: instance)
        do {
            return (try await answer(operation, call), nil)
        } catch {
            return (nil, error.rawValue)
        }
    }

    private func answer(_ operation: String, _ call: UserscriptCall) async throws(UserscriptRefusal) -> Any? {
        switch operation {
        case "run":
            if let webView = call.webView { pages.page(in: webView).started(call.instance) }
        case "setValue": try values.set(call)
        case "xhr": return try await requests.send(call)
        case "abort": requests.abort(call)
        case "menu": menuCommands.register(call)
        case "unmenu": menuCommands.unregister(call)
        case "openInTab": return try tabs.open(call)
        case "closeTab": tabs.close(call)
        case "closeWindow": try tabs.closeWindow(call)
        case "focusWindow": try tabs.focusWindow(call)
        case "notify": return try await notifications.show(call)
        case "unnotify": notifications.remove(call)
        case "clipboard": try GMClipboard.set(call)
        case "download": try await downloads.start(call)
        case "abortDownload": downloads.abort(call)
        default: throw .unknown
        }
        return nil
    }
}
