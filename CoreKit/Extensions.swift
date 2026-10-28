import AppKit
import WebKit

/// What the shell does for extensions: it owns the window and the tabs.
@MainActor
public protocol ExtensionHost: AnyObject {
    var extensionTabs: [Tab] { get }
    var extensionActiveTab: Tab? { get }
    func extensionOpen(_ url: URL?, active: Bool) -> Tab
    func extensionSelect(_ tab: Tab)
    func extensionClose(_ tab: Tab)
    /// Show an action's popup, anchored to its button.
    func extensionPresent(_ action: WKWebExtension.Action)
    func extensionActionsChanged()
    var extensionWindowFrame: CGRect { get }
}

/// Extensions, on WebKit's own engine (the one Safari uses), installed from
/// a Chrome Web Store link or a folder. They are the one thing in Core that
/// keeps data on purpose: an extension's own storage (a password manager's
/// vault) lives in a store of its own that no website ever loads into.
///
/// Installing one is a trade the person makes: content scripts can change
/// a page in ways the page can see.
@MainActor
public final class Extensions: NSObject {
    public static let shared = Extensions()

    public weak var host: ExtensionHost?
    public let controller: WKWebExtensionController
    public private(set) var contexts: [WKWebExtensionContext] = []
    public private(set) var trouble: String?

    public struct Installed: Codable, Equatable {
        public var id: String
        public var name: String
        /// Where it came from: a Chrome Web Store id, or nil for a folder.
        public var storeID: String?
    }

    public private(set) var installed: [Installed] = Store.read([Installed].self, "extensions.json") ?? []

    static var folder: URL {
        let url = Store.directory.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The extension controller's storage and its pages' data store.
    static let storeIDs = [UUID(uuidString: "C0DE0000-0000-4000-8000-0000000E7E45")!, UUID(uuidString: "C0DE0000-0000-4000-8000-00000000E75D")!]

    private override init() {
        let configuration = WKWebExtensionController.Configuration(identifier: Extensions.storeIDs[0])
        let store = WKWebsiteDataStore(forIdentifier: Extensions.storeIDs[1])
        configuration.defaultWebsiteDataStore = store
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        views.websiteDataStore = store
        // The tabs' user agent to the letter: WebKit stops extension workers
        // whose user agent differs from the last page's and doesn't restart them.
        views.applicationNameForUserAgent = Engine.applicationName
        configuration.webViewConfiguration = views
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    public func start() {
        Task {
            for item in installed { await load(item) }
            host?.extensionActionsChanged()
        }
    }

    private func load(_ item: Installed) async {
        let url = Extensions.folder.appendingPathComponent(item.id, isDirectory: true)
        do {
            let ext = try await WKWebExtension(resourceBaseURL: url)
            let context = WKWebExtensionContext(for: ext)
            // A stable identifier: what the extension stored comes back.
            context.uniqueIdentifier = item.id
            context.isInspectable = false
            // Installing it was the consent: it gets what it asked for.
            for permission in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in ext.requestedPermissionMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            for pattern in ext.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            try controller.load(context)
            contexts.append(context)
            if let name = ext.displayName, let i = installed.firstIndex(where: { $0.id == item.id }), installed[i].name != name {
                installed[i].name = name
                Store.write(installed, "extensions.json")
            }
        } catch {
            trouble = "\(item.name): \(error.localizedDescription)"
        }
    }

    /// A Chrome Web Store link or a bare extension id.
    public func install(from text: String) async {
        guard let id = Crx.id(in: text) else { trouble = Crx.Refused.notAnID.localizedDescription; return }
        do {
            let crx = try await Crx.fetch(id)
            let zip = try Crx.verifiedZip(crx, id: id)
            let folder = Extensions.folder.appendingPathComponent(id, isDirectory: true)
            try Crx.unpack(zip, into: folder)
            await add(Installed(id: id, name: Extensions.name(in: folder) ?? id, storeID: id))
        } catch {
            trouble = error.localizedDescription
        }
    }

    public func installFolder(_ source: URL) async {
        let id = Crx.unpackedID(for: source)
        let folder = Extensions.folder.appendingPathComponent(id, isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.copyItem(at: source, to: folder)
            await add(Installed(id: id, name: Extensions.name(in: folder) ?? source.lastPathComponent, storeID: nil))
        } catch {
            trouble = error.localizedDescription
        }
    }

    private func add(_ item: Installed) async {
        await remove(item.id, keepFiles: true)
        installed.append(item)
        Store.write(installed, "extensions.json")
        trouble = nil
        await load(item)
        host?.extensionActionsChanged()
    }

    public func remove(_ id: String, keepFiles: Bool = false) async {
        for context in contexts where context.uniqueIdentifier == id {
            try? controller.unload(context)
        }
        contexts.removeAll { $0.uniqueIdentifier == id }
        installed.removeAll { $0.id == id }
        Store.write(installed, "extensions.json")
        if !keepFiles {
            try? FileManager.default.removeItem(at: Extensions.folder.appendingPathComponent(id))
        }
        host?.extensionActionsChanged()
    }

    static func name(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = manifest["name"] as? String
        else { return nil }
        if name.hasPrefix("__MSG_") {
            return folder.lastPathComponent
        }
        return name
    }

    /// The button for each extension that has one, for the active tab.
    public func actions() -> [WKWebExtension.Action] {
        contexts.compactMap { $0.action(for: host?.extensionActiveTab) }
    }

    public func perform(_ action: WKWebExtension.Action) {
        action.webExtensionContext?.performAction(for: host?.extensionActiveTab)
    }

    // MARK: Telling WebKit what the tabs are doing

    public func didOpen(_ tab: Tab) { controller.didOpenTab(tab) }
    public func didClose(_ tab: Tab) { controller.didCloseTab(tab, windowIsClosing: false) }
    func didChange(_ tab: Tab, _ properties: WKWebExtension.TabChangedProperties) {
        controller.didChangeTabProperties(properties, for: tab)
    }
    public func didActivate(_ tab: Tab, previous: Tab?) { controller.didActivateTab(tab, previousActiveTab: previous) }
    public func didMove(_ tab: Tab, from index: Int) {
        controller.didMoveTab(tab, from: index, in: CoreWindow.shared)
    }
    public func windowOpened() {
        controller.didOpenWindow(CoreWindow.shared)
        controller.didFocusWindow(CoreWindow.shared)
    }
}

/// Core has one window; extensions see it as this.
@MainActor
final class CoreWindow: NSObject, WKWebExtensionWindow {
    static let shared = CoreWindow()

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { Extensions.shared.host?.extensionTabs ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { Extensions.shared.host?.extensionActiveTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { Extensions.shared.host?.extensionWindowFrame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { NSScreen.main?.frame ?? .null }
}

extension Tab: WKWebExtensionTab {
    public func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { CoreWindow.shared }
    public func indexInWindow(for context: WKWebExtensionContext) -> Int {
        Extensions.shared.host?.extensionTabs.firstIndex { $0 === self } ?? NSNotFound
    }
    public func title(for context: WKWebExtensionContext) -> String? { title }
    public func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    public func url(for context: WKWebExtensionContext) -> URL? { url }
    public func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    public func isSelected(for context: WKWebExtensionContext) -> Bool { Extensions.shared.host?.extensionActiveTab === self }
    public func activate(for context: WKWebExtensionContext) async throws { Extensions.shared.host?.extensionSelect(self) }
    public func close(for context: WKWebExtensionContext) async throws { Extensions.shared.host?.extensionClose(self) }
    public func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws { reload() }
    public func goBack(for context: WKWebExtensionContext) async throws { goBack() }
    public func goForward(for context: WKWebExtensionContext) async throws { goForward() }
    public func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws { load(url) }
    public func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { opener }
}

extension Extensions: WKWebExtensionControllerDelegate {
    public func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [CoreWindow.shared]
    }

    public func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        CoreWindow.shared
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        host?.extensionOpen(configuration.url, active: configuration.shouldBeActive)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        // One window: a new "window" is a new tab (a password manager's
        // pop-out vault, say).
        if let url = configuration.tabURLs.first { _ = host?.extensionOpen(url, active: true) }
        return CoreWindow.shared
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        if let url = extensionContext.optionsPageURL { _ = host?.extensionOpen(url, active: true) }
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        (permissions, nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        (urls, nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        (matchPatterns, nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        host?.extensionActionsChanged()
    }

    public func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        host?.extensionPresent(action)
    }
}
