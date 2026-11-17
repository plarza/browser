import Foundation
import Observation

/// The whole of what a person can set. Nothing in here can switch a
/// protection off; there is no key that would.
public struct Settings: Codable, Equatable, Sendable {
    /// A search URL with `%s` where the words go. Empty until someone sets
    /// one: there is no default.
    public var searchTemplate = ""
    /// Domains whose jar is kept on disk. A domain covers its subdomains.
    public var whitelist: [String] = []
    /// Filter lists fetched once a day.
    public var filterLists = Settings.defaultFilterLists
    /// Follow the system unless a light or dark appearance is chosen.
    public var appearance = Appearance.system
    /// Where a new tab goes in the list.
    public var newTabPosition = TabPosition.below
    /// What a blank tab shows: a picture, a colour, or the desktop, frosted.
    public var newTabPage = NewTabPage.image
    public var newTabColor = "#2E4B76"
    /// The new tab page's picture or colour fills the whole window, behind
    /// a frosted sidebar.
    public var fill = false
    /// How blurred and how see-through the sidebar is over a filled window,
    /// anywhere from 0 to `fillMax`.
    public var fillBlur = 6.0
    public var fillTransparency = 4.0
    public static let fillMax = 10.0

    public enum Appearance: String, Codable, CaseIterable, Sendable {
        case system, light, dark
    }

    public enum TabPosition: String, Codable, CaseIterable, Sendable {
        case below, top, bottom
    }

    public enum NewTabPage: String, Codable, CaseIterable, Sendable {
        case image, color, blank
    }

    public static let defaultFilterLists = [
        "https://ublockorigin.github.io/uAssets/filters/filters.min.txt",
        "https://ublockorigin.github.io/uAssets/filters/privacy.min.txt",
        "https://ublockorigin.github.io/uAssets/filters/badware.min.txt",
        "https://ublockorigin.github.io/uAssets/filters/quick-fixes.min.txt",
        "https://easylist.to/easylist/easylist.txt",
        "https://easylist.to/easylist/easyprivacy.txt",
        "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=1&mimetype=plaintext",
        "https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-ag-online.txt",
        "https://filters.adtidy.org/extension/ublock/filters/18.txt",
    ]

    public init() {}

    /// A file saved by an older Browser lacks the newer keys: those keep
    /// their defaults, and everything it did save is kept.
    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys, into value: inout Value) {
            if let found = try? saved.decodeIfPresent(Value.self, forKey: key) { value = found }
        }
        read(.searchTemplate, into: &searchTemplate)
        read(.whitelist, into: &whitelist)
        read(.filterLists, into: &filterLists)
        read(.appearance, into: &appearance)
        read(.newTabPosition, into: &newTabPosition)
        read(.newTabPage, into: &newTabPage)
        read(.newTabColor, into: &newTabColor)
        read(.fill, into: &fill)
        read(.fillBlur, into: &fillBlur)
        read(.fillTransparency, into: &fillTransparency)
    }

    /// A picture someone chose for blank tabs, kept beside the settings.
    public static var newTabImage: URL { Store.url("newtab-image") }

    /// The picture blank tabs show now: the chosen one, else Browser's own.
    public static var newTabImageInUse: URL? {
        FileManager.default.fileExists(atPath: newTabImage.path) ? newTabImage : Bundle.main.url(forResource: "morning", withExtension: "webp")
    }
}

/// A search engine Settings offers by name; any other is a template typed in.
public struct SearchEngine: Identifiable, Equatable, Sendable {
    public let name: String
    public let template: String
    /// Its picture's name among the app's resources (`release/engines`).
    public let icon: String
    public var id: String { name }

    public static let all = [
        SearchEngine(name: "Google", template: "https://www.google.com/search?q=%s", icon: "google.png"),
        SearchEngine(name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s", icon: "duckduckgo.png"),
        SearchEngine(name: "Brave", template: "https://search.brave.com/search?q=%s", icon: "brave.svg"),
        SearchEngine(name: "Startpage", template: "https://www.startpage.com/do/search?query=%s", icon: "startpage.png"),
        SearchEngine(name: "Kagi", template: "https://kagi.com/search?q=%s", icon: "kagi.png"),
    ]
}

/// The settings in use, saved as they change.
@MainActor @Observable
public final class Preferences {
    public static let shared = Preferences()

    public var settings: Settings {
        get { saved }
        set { save(newValue) }
    }

    private var saved: Settings

    /// Bumped when the chosen new tab picture's file changes under the same setting.
    public private(set) var newTabImageVersion = 0

    private init() {
        saved = Store.read(Settings.self, "settings.json") ?? Settings()
    }

    private func save(_ new: Settings) {
        var new = new
        new.whitelist = Whitelist.normalise(new.whitelist)
        let old = saved
        guard new != old else { return }
        saved = new
        Store.write(new, "settings.json")
        // A domain taken off the whitelist leaves nothing behind.
        for gone in Set(old.whitelist).subtracting(new.whitelist) {
            Task { await Identity.forget(whitelisted: gone) }
            if !History.shared.knows(host: gone) { Favicons.shared.forget(host: gone) }
        }
        if new.filterLists != old.filterLists { Blocker.shared.refresh(force: true) }
    }

    public func newTabImageChanged() { newTabImageVersion += 1 }
}

/// The domains whose jar survives. Each gets a data store of its own on
/// disk, so a site stays logged in across tabs and relaunches.
@MainActor
public enum Whitelist {
    /// Hosts only, lowercased, each once, in the order given.
    public nonisolated static func normalise(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains.compactMap { raw in
            var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let host = URL(string: domain.contains("://") ? domain : "https://" + domain)?.host { domain = host }
            while domain.hasPrefix(".") { domain.removeFirst() }
            guard !domain.isEmpty, seen.insert(domain).inserted else { return nil }
            return domain
        }
    }

    /// The whitelisted domain a host falls under, if any. The longest match
    /// wins, so `a.example.com` and `example.com` can be separate jars.
    public static func domain(for host: String?) -> String? {
        guard let host = host?.lowercased() else { return nil }
        return Preferences.shared.settings.whitelist
            .filter { host == $0 || host.hasSuffix("." + $0) }
            .max { $0.count < $1.count }
    }

    nonisolated static func storeID(for domain: String) -> UUID { UUID(hashing: "browser.jar." + domain) }
}
