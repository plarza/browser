import WebKit

/// Puts the scripts into the pages. As with the scriptlets, the scripts
/// for an address are worked out here as each frame's navigation is
/// decided, and only those go into the web view, before any of the page's
/// own; a site no script names gets none.
@MainActor
final class UserscriptInjection {
    /// What one web view's content controller has been given.
    private final class Given {
        /// Each script's function, by the script's id.
        var wrapped: [String: Copy] = [:]
        /// Each @unwrap script's copy for the top frame.
        var unwrapped: [String: Copy] = [:]
        /// The worlds the bridge's handler has been put in.
        var worlds: Set<World> = []
    }

    /// A script as it went into a web view.
    private struct Copy {
        let scripts: [WKUserScript]
        let stamp: Stamp
    }

    /// The state of a script and of its values when a copy was made: a
    /// copy with an older stamp is made again at the web view's next load.
    private struct Stamp: Equatable {
        let script: Int
        let values: Int
    }

    private enum World {
        case page, content

        @MainActor var contentWorld: WKContentWorld { self == .content ? UserscriptBridge.world : .page }
    }

    private let bridge: UserscriptBridge
    private let values: UserscriptValues
    private let given = NSMapTable<WKUserContentController, Given>.weakToStrongObjects()
    /// Raised whenever a script's source or switch changes.
    private var revisions: [String: Int] = [:]

    init(bridge: UserscriptBridge, values: UserscriptValues) {
        self.bridge = bridge
        self.values = values
    }

    /// Before a frame in `controller`'s web view loads `address`: the
    /// scripts for that address join the ones the web view already has.
    /// A web view keeps its scripts across links, so each checks the
    /// address again as it starts.
    ///
    /// An @unwrap script runs as written, at the top level of the page, so
    /// it can't check the address itself: its copy for the top frame is
    /// decided again at every top-frame navigation. In frames it runs in its
    /// own function, like any other.
    func prepare(_ controller: WKUserContentController, for address: String, mainFrame: Bool,
                 scripts: [Userscript], rules: [String: UserscriptRules]) {
        let given = given(to: controller)
        for script in scripts {
            let meta = script.meta
            let source = UserscriptSource(script: script, meta: meta, bridge: bridge)
            let runs = script.enabled && rules[script.id]?.matches(address) == true
            let stamp = Stamp(script: revisions[script.id, default: 0], values: values.revision(of: script.id))
            if meta.unwrap {
                if mainFrame {
                    if let have = given.unwrapped[script.id], !runs || have.stamp != stamp {
                        have.scripts.forEach(controller.remove)
                        given.unwrapped[script.id] = nil
                    }
                    if runs, given.unwrapped[script.id] == nil {
                        let time: WKUserScriptInjectionTime = meta.runAt == "document-start" ? .atDocumentStart : .atDocumentEnd
                        let unwrapped = WKUserScript(source: source.unwrapped, injectionTime: time, forMainFrameOnly: true, in: .page)
                        // Counted as running from Browser's own world, where the secret is safe.
                        let started = WKUserScript(source: source.started, injectionTime: time, forMainFrameOnly: true,
                                                   in: world(.content, in: controller, given))
                        controller.addUserScript(unwrapped)
                        controller.addUserScript(started)
                        given.unwrapped[script.id] = Copy(scripts: [unwrapped, started], stamp: stamp)
                    }
                }
                if meta.noframes { continue }
            }
            guard runs else { continue }
            if let have = given.wrapped[script.id] {
                if have.stamp == stamp { continue }
                have.scripts.forEach(controller.remove)
            }
            // Always at the start of the document: the script itself waits for its @run-at.
            let wrapped = WKUserScript(source: source.wrapped(rules: rules[script.id] ?? UserscriptRules(meta), values: values.values(of: script.id)),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: meta.noframes,
                                       in: world(meta.injectInto == "content" ? .content : .page, in: controller, given))
            controller.addUserScript(wrapped)
            given.wrapped[script.id] = Copy(scripts: [wrapped], stamp: stamp)
        }
    }

    /// A script was changed, switched or removed: every web view drops its
    /// copy. The next load in each gets the new one, if it still matches.
    func changed(_ id: String) {
        revisions[id, default: 0] += 1
        for controller in given.keyEnumerator().allObjects as? [WKUserContentController] ?? [] {
            guard let given = given.object(forKey: controller) else { continue }
            for copy in [given.wrapped.removeValue(forKey: id), given.unwrapped.removeValue(forKey: id)] {
                copy?.scripts.forEach(controller.remove)
            }
        }
    }

    private func given(to controller: WKUserContentController) -> Given {
        if let given = given.object(forKey: controller) { return given }
        let given = Given()
        self.given.setObject(given, forKey: controller)
        return given
    }

    /// The world a script goes into, with the bridge's handler in it: the
    /// handler is there only where a script runs.
    private func world(_ world: World, in controller: WKUserContentController, _ given: Given) -> WKContentWorld {
        if given.worlds.insert(world).inserted {
            controller.addScriptMessageHandler(bridge, contentWorld: world.contentWorld, name: UserscriptBridge.handlerName)
        }
        return world.contentWorld
    }
}
