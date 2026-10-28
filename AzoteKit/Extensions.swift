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

/// Safari web extensions, from the apps installed on this Mac, on WebKit's
/// own extension engine (the one Safari uses). They are the one thing in
/// Azote that keeps data on purpose: an extension's own storage (a password
/// manager's vault) lives in a store of its own that no website ever loads
/// into, and stays when the extension is turned off.
///
/// Turning one on is a trade the person makes: content scripts can change
/// a page in ways the page can see.
@MainActor
public final class Extensions: NSObject {
    public static let shared = Extensions()

    public weak var host: ExtensionHost?
    public let controller: WKWebExtensionController
    public private(set) var contexts: [WKWebExtensionContext] = []
    public private(set) var trouble: String?

    /// A Safari web extension found inside an app, named by its bundle id.
    public struct Found: Identifiable {
        public let id: String
        public let name: String
        let bundle: Bundle
    }

    public private(set) var found: [Found] = []
    /// The extensions turned on, in their buttons' order.
    public private(set) var enabled: [String] = Store.read([String].self, "extensions.json") ?? []

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
        found = Extensions.scan()
        Task {
            for id in enabled { await load(id) }
            host?.extensionActionsChanged()
        }
    }

    /// Every app in /Applications and ~/Applications, and the Safari web
    /// extensions in its PlugIns.
    static func scan() -> [Found] {
        let files = FileManager.default
        let list = { (url: URL) in (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] }
        return files.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
            .flatMap(list).filter { $0.pathExtension == "app" }
            .flatMap { list($0.appending(path: "Contents/PlugIns")) }
            .compactMap(Bundle.init(url:))
            .compactMap { bundle in
                let point = (bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])?["NSExtensionPointIdentifier"] as? String
                guard point == "com.apple.Safari.web-extension", let id = bundle.bundleIdentifier else { return nil }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? bundle.object(forInfoDictionaryKey: "CFBundleName")
                return Found(id: id, name: name as? String ?? id, bundle: bundle)
            }
    }

    private func load(_ id: String) async {
        guard let item = found.first(where: { $0.id == id }) else { return }
        do {
            let ext = try await WKWebExtension(appExtensionBundle: item.bundle)
            let context = WKWebExtensionContext(for: ext)
            // A stable identifier: what the extension stored comes back.
            context.uniqueIdentifier = id
            context.isInspectable = false
            // Azote's regular tabs use ephemeral (WebKit private) stores.
            context.hasAccessToPrivateData = true
            // Turning it on was the consent: it gets what it asked for.
            for permission in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in ext.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            try controller.load(context)
            contexts.append(context)
        } catch {
            trouble = "\(item.name): \(error.localizedDescription)"
        }
    }

    public func setEnabled(_ id: String, _ on: Bool) async {
        for context in contexts where context.uniqueIdentifier == id { try? controller.unload(context) }
        contexts.removeAll { $0.uniqueIdentifier == id }
        enabled.removeAll { $0 == id }
        trouble = nil
        if on {
            enabled.append(id)
            await load(id)
        }
        Store.write(enabled, "extensions.json")
        host?.extensionActionsChanged()
    }

    func context(for url: URL) -> WKWebExtensionContext? {
        contexts.first { $0.baseURL.scheme == url.scheme && $0.baseURL.host == url.host }
    }

    /// The button for each extension that has one, for the active tab.
    public func actions() -> [WKWebExtension.Action] {
        enabled.compactMap { id in
            contexts.first { $0.uniqueIdentifier == id }?.action(for: host?.extensionActiveTab)
        }
    }

    public func move(_ id: String, before next: String?) {
        guard enabled.contains(id) else { return }
        enabled.removeAll { $0 == id }
        enabled.insert(id, at: next.flatMap(enabled.firstIndex(of:)) ?? enabled.count)
        Store.write(enabled, "extensions.json")
        host?.extensionActionsChanged()
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
        controller.didMoveTab(tab, from: index, in: AzoteWindow.shared)
    }
    public func windowOpened() {
        controller.didOpenWindow(AzoteWindow.shared)
        controller.didFocusWindow(AzoteWindow.shared)
    }
}

/// Azote has one window; extensions see it as this.
@MainActor
final class AzoteWindow: NSObject, WKWebExtensionWindow {
    static let shared = AzoteWindow()

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { Extensions.shared.host?.extensionTabs ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { Extensions.shared.host?.extensionActiveTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { Extensions.shared.host?.extensionWindowFrame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { NSScreen.main?.frame ?? .null }
}

extension Tab: WKWebExtensionTab {
    public func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { AzoteWindow.shared }
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
        [AzoteWindow.shared]
    }

    public func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        AzoteWindow.shared
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        host?.extensionOpen(configuration.url, active: configuration.shouldBeActive)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        // One window: a new "window" is a new tab (a password manager's
        // pop-out vault, say).
        if let url = configuration.tabURLs.first { _ = host?.extensionOpen(url, active: true) }
        return AzoteWindow.shared
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
