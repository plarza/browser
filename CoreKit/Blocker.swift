import Foundation
import WebKit

/// The blocker. Rules are compiled into WebKit content rule lists, which
/// WebKit enforces in its networking and style resolver: before a request
/// is made, before an element is drawn, with nothing running in the page.
///
/// A small built-in list works from the first launch; the filter lists in
/// Settings are fetched once a day and compiled behind it.
@MainActor
public final class Blocker {
    public static let shared = Blocker()

    private let store: WKContentRuleListStore?
    private(set) var lists: [WKContentRuleList] = []
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var refreshing = false

    /// The last thing that went wrong fetching or compiling, for Settings.
    public private(set) var trouble: String?
    public private(set) var ruleCount = 0

    private static let filtersID = "core-filters"
    private static let baseID = "core-base"

    private init() {
        let folder = Store.url("Rules")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: folder)
    }

    /// Every tab's content controller comes from here, so every tab gets
    /// every list, and a list compiled later reaches tabs already open.
    func controller() -> WKUserContentController {
        let controller = WKUserContentController()
        for list in lists { controller.add(list) }
        controllers.add(controller)
        return controller
    }

    private func install(_ list: WKContentRuleList, replacing id: String) {
        for controller in controllers.allObjects {
            for old in lists where old.identifier == id { controller.remove(old) }
            controller.add(list)
        }
        lists.removeAll { $0.identifier == id }
        lists.append(list)
    }

    public func start() {
        Task {
            await loadBase()
            if let list = try? await store?.contentRuleList(forIdentifier: Blocker.filtersID) {
                install(list, replacing: Blocker.filtersID)
            }
            refresh(force: false)
        }
        Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in Blocker.shared.refresh(force: false) }
        }
    }

    private func loadBase() async {
        let rules = Blocker.base.map { domain -> [String: Any] in
            ["trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?" + domain.replacingOccurrences(of: ".", with: "\\.") + "[/:]",
                         "load-type": ["third-party"]],
             "action": ["type": "block"]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8),
              let list = try? await store?.compileContentRuleList(forIdentifier: Blocker.baseID, encodedContentRuleList: json)
        else { return }
        install(list, replacing: Blocker.baseID)
    }

    /// Fetch and compile when a day has passed, or now when `force`.
    public func refresh(force: Bool) {
        let last = Store.read(Date.self, "filters-fetched.json") ?? .distantPast
        guard !refreshing, force || Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        refreshing = true
        let urls = Preferences.shared.settings.filterLists.compactMap(URL.init(string:))
        Task {
            defer { refreshing = false }
            let texts = await Blocker.fetch(urls)
            guard !texts.isEmpty else { trouble = "Couldn't fetch any filter list."; return }
            let output = await Task.detached { FilterList.compile(texts) }.value
            do {
                let json = try await Task.detached { () throws -> String in
                    let data = try JSONSerialization.data(withJSONObject: output.rules)
                    return String(decoding: data, as: UTF8.self)
                }.value
                guard let store else { return }
                let list = try await store.compileContentRuleList(forIdentifier: Blocker.filtersID, encodedContentRuleList: json)
                guard let list else { return }
                install(list, replacing: Blocker.filtersID)
                ruleCount = output.rules.count
                trouble = texts.count < urls.count ? "\(urls.count - texts.count) of \(urls.count) lists couldn't be fetched." : nil
                Store.write(Date(), "filters-fetched.json")
            } catch {
                trouble = "Compiling the filter lists failed: \(error.localizedDescription)"
            }
        }
    }

    /// No cookies, no cache, nothing that ties one day's fetch to the next.
    static func fetch(_ urls: [URL]) async -> [String] {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(await Engine.applicationName)"]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: String?.self) { group in
            for url in urls {
                group.addTask {
                    guard let (data, response) = try? await session.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200
                    else { return nil }
                    return String(decoding: data, as: UTF8.self)
                }
            }
            var texts: [String] = []
            for await text in group { if let text { texts.append(text) } }
            return texts
        }
    }

    /// Third parties whose only job is to watch or to sell; from Search's
    /// Shield (MIT, Office Commun). Enough to be useful before the first
    /// fetch has finished.
    static let base = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
    ]
}
