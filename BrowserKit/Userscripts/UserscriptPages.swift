import Observation
import WebKit

/// A running copy of a script: a frame in a web view, in a world. Also who
/// to tell about something that happens later: a value another tab set, a
/// tab the script opened closing, its notification clicked, its download's
/// progress.
@MainActor
struct UserscriptInstance {
    /// The copy's own name for itself, made as it starts.
    let id: String
    /// The id of the script it is a copy of.
    let script: String
    weak var webView: WKWebView?
    let frame: WKFrameInfo
    let world: WKContentWorld
    /// The function the copy left on its `window` to be told things by.
    let hook: String

    func push(_ message: [String: Any]) async {
        guard let webView else { return }
        _ = try? await webView.callAsyncJavaScript("window[hook](message)", arguments: ["hook": hook, "message": message],
                                                   in: frame, contentWorld: world)
    }
}

extension Userscripts {
    /// A command a running script registered with GM_registerMenuCommand.
    public struct MenuCommand: Identifiable {
        public let id: String
        public let caption: String
        /// The id of the script that registered it.
        public let script: String
        /// The command's own id, as the script knows it.
        let command: String
        let instance: UserscriptInstance
    }

    /// A script that applies to a page: whether it is running there now,
    /// and the commands it registered.
    public struct OnPage: Identifiable {
        public let script: Userscript
        public let running: Bool
        public let commands: [MenuCommand]
        public var id: String { script.id }
    }
}

/// What runs in the document a web view shows. Observable, so a view that
/// lists a page's scripts is told when one starts or changes its commands.
@MainActor @Observable
final class UserscriptPage {
    private(set) var instances: [UserscriptInstance] = []
    private(set) var commands: [Userscripts.MenuCommand] = []
    /// How many documents the web view has shown. Reading it is how a view
    /// hears of a new page that no script ran on, before or after.
    private(set) var documents = 0

    func started(_ instance: UserscriptInstance) {
        instances.append(instance)
    }

    /// Registers `command`, in place of the one the same copy registered
    /// under the same id.
    func add(_ command: Userscripts.MenuCommand) {
        remove(command.command, of: command.instance.id)
        commands.append(command)
    }

    func remove(_ command: String, of instance: String) {
        commands.removeAll { $0.instance.id == instance && $0.command == command }
    }

    /// A new document in the main frame: what ran before has gone.
    func changed() {
        instances = []
        commands = []
        documents += 1
    }
}

/// Every web view's page, for as long as the web view lasts.
@MainActor
final class UserscriptPages {
    private let pages = NSMapTable<WKWebView, UserscriptPage>.weakToStrongObjects()

    /// The page `webView` shows. Made when first asked for, so whoever reads
    /// it before any script runs is still told when one does.
    func page(in webView: WKWebView) -> UserscriptPage {
        if let page = pages.object(forKey: webView) { return page }
        let page = UserscriptPage()
        pages.setObject(page, forKey: webView)
        return page
    }

    /// A new document in `webView`'s main frame. A web view nobody has
    /// asked about has nothing to forget.
    func changed(in webView: WKWebView) {
        pages.object(forKey: webView)?.changed()
    }

    /// Every running copy of a script, in every web view.
    func instances(of script: String) -> [UserscriptInstance] {
        let webViews = pages.keyEnumerator().allObjects as? [WKWebView] ?? []
        return webViews.flatMap { pages.object(forKey: $0)?.instances ?? [] }.filter { $0.script == script }
    }
}
