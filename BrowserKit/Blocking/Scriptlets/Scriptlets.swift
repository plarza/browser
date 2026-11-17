import Foundation
import WebKit

/// Puts each page's scriptlets into its web view.
///
/// Nothing runs on a site no rule names. A page's scriptlets are worked out
/// here, from its host, as each frame's navigation is decided, and only
/// those reach the page.
@MainActor
public final class Scriptlets {
    public static let shared = Scriptlets()

    /// The filter lists' scriptlet rules: the last launch's, until the
    /// lists have compiled again.
    public internal(set) var rules = ScriptletRules()

    /// What the frames of one content controller's web view run, and the
    /// script that carries it there.
    private final class Installed {
        var hosts: [String: [String]] = [:]
        var script: WKUserScript?
    }

    private let installed = NSMapTable<WKUserContentController, Installed>.weakToStrongObjects()

    private init() {}

    /// Before a frame in `controller`'s web view loads `url`: that host's
    /// scriptlets join the ones its other frames already have.
    func prepare(_ controller: WKUserContentController, for url: URL?) {
        guard let scheme = url?.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url?.host?.lowercased(), !host.isEmpty
        else { return }
        let state = state(of: controller)
        guard state.hosts[host] == nil else { return }
        let calls = rules.calls(for: host)
        guard !calls.isEmpty else { return }
        state.hosts[host] = calls
        let script = WKUserScript(source: ScriptletLibrary.source(for: state.hosts), injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false, in: .page)
        // First, before anything else runs in the page.
        let others = controller.userScripts.filter { $0 !== state.script }
        controller.removeAllUserScripts()
        controller.addUserScript(script)
        others.forEach(controller.addUserScript)
        state.script = script
    }

    private func state(of controller: WKUserContentController) -> Installed {
        if let state = installed.object(forKey: controller) { return state }
        let state = Installed()
        installed.setObject(state, forKey: controller)
        return state
    }
}
