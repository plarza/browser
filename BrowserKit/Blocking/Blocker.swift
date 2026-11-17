import Foundation
import Observation
import WebKit

/// The blocker. Rules are compiled into WebKit content rule lists, which
/// WebKit enforces in its networking and style resolver: before a request
/// is made, before an element is drawn, with nothing running in the page.
///
/// A small built-in list works from the first launch; the filter lists in
/// Settings are fetched once a day and compiled behind it.
@MainActor @Observable
public final class Blocker {
    public static let shared = Blocker()

    /// The last thing that went wrong fetching or compiling, for Settings.
    public private(set) var trouble: String?
    /// How many rules the lists compiled into.
    public private(set) var ruleCount = 0
    /// A fetch and compile is under way.
    public private(set) var isRefreshing = false
    /// When the lists were last fetched.
    public private(set) var lastFetched: Date?

    @ObservationIgnored private let lists = RuleLists()

    /// Raised when the same lists compile into different rules, so lists
    /// compiled by an older Browser are compiled again at launch.
    private static let format = 3

    private init() {
        lastFetched = Store.read(Date.self, "filters-fetched.json")
    }

    /// Every tab's content controller comes from here, so every tab gets
    /// every list, and a list compiled later reaches tabs already open.
    func contentController() -> WKUserContentController {
        lists.controller()
    }

    /// Loads the compiled lists and keeps them fresh: once at launch.
    public func start() {
        Task {
            await lists.load()
            let scriptlets = await Task.detached { Store.read(ScriptletRules.self, "scriptlets.json") }.value
            if let scriptlets { Scriptlets.shared.rules = scriptlets }
            refresh(force: scriptlets == nil || Store.read(Int.self, "filters-format.json") != Blocker.format)
            while true {
                try? await Task.sleep(for: .seconds(60 * 60))
                refresh(force: false)
            }
        }
    }

    /// Fetch and compile when a day has passed, or now when `force`.
    public func refresh(force: Bool) {
        guard !isRefreshing, force || Date().timeIntervalSince(lastFetched ?? .distantPast) > 24 * 60 * 60 else { return }
        isRefreshing = true
        let urls = Blocker.filterLists
        Task {
            await update(from: urls)
            isRefreshing = false
            // Edited while this was under way: what was just compiled isn't
            // the lists Settings has now.
            if urls != Blocker.filterLists { refresh(force: true) }
        }
    }

    private static var filterLists: [URL] {
        Preferences.shared.settings.filterLists.compactMap(URL.init(string:))
    }

    private func update(from urls: [URL]) async {
        let fetched = await FilterList.fetch(urls)
        guard !fetched.isEmpty else { trouble = "Couldn't fetch any filter list."; return }
        do {
            // Off the main actor: several hundred thousand lines.
            let compiled = try await Task.detached { try FilterCompiler.compile(fetched) }.value
            try await lists.replaceFilters(with: compiled.lists)
            Scriptlets.shared.rules = compiled.scriptlets
            await Task.detached { Store.write(compiled.scriptlets, "scriptlets.json") }.value
            ruleCount = compiled.ruleCount
            trouble = fetched.count < urls.count ? "\(urls.count - fetched.count) of \(urls.count) lists couldn't be fetched." : nil
            let now = Date()
            lastFetched = now
            Store.write(now, "filters-fetched.json")
            Store.write(Blocker.format, "filters-format.json")
        } catch {
            trouble = "Compiling the filter lists failed: \(error.localizedDescription)"
        }
    }
}
