import CryptoKit
import Foundation

/// The whole of what a person can set. Nothing in here can switch a
/// protection off; there is no key that would.
public struct Settings: Codable, Equatable {
    /// A search URL with `%s` where the words go. Empty until someone sets
    /// one: there is no default.
    public var searchTemplate: String = ""
    /// Domains whose jar is kept on disk. A domain covers its subdomains.
    public var whitelist: [String] = []
    /// Filter lists fetched once a day.
    public var filterLists: [String] = Settings.defaultFilterLists
    /// Where a new tab goes in the list.
    public var newTabPosition: TabPosition = .below
    /// What a blank tab shows: a picture, a colour, or the desktop, frosted.
    public var newTabPage: NewTabPage = .image
    public var newTabColor: String = "#2E4B76"
    /// The new tab page's picture or colour fills the whole window, behind
    /// a frosted sidebar.
    public var fill: Bool = false

    public enum NewTabPage: String, Codable, CaseIterable {
        case image, color, blank
    }

    /// A picture someone chose for blank tabs, kept beside the settings.
    /// Without one, Core's own.
    public static var newTabImage: URL { Store.directory.appendingPathComponent("newtab-image") }

    /// The picture blank tabs show now: the chosen one, else Core's own.
    public static var newTabImageInUse: URL? {
        FileManager.default.fileExists(atPath: newTabImage.path) ? newTabImage : Bundle.main.url(forResource: "morning", withExtension: "webp")
    }

    public enum TabPosition: String, Codable, CaseIterable {
        case below, top, bottom
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searchTemplate = try c.decodeIfPresent(String.self, forKey: .searchTemplate) ?? ""
        whitelist = try c.decodeIfPresent([String].self, forKey: .whitelist) ?? []
        filterLists = try c.decodeIfPresent([String].self, forKey: .filterLists) ?? Settings.defaultFilterLists
        newTabPosition = try c.decodeIfPresent(TabPosition.self, forKey: .newTabPosition) ?? .below
        newTabPage = try c.decodeIfPresent(NewTabPage.self, forKey: .newTabPage) ?? .image
        newTabColor = try c.decodeIfPresent(String.self, forKey: .newTabColor) ?? "#2E4B76"
        fill = try c.decodeIfPresent(Bool.self, forKey: .fill) ?? false
    }
}

/// Where Core keeps the little it keeps.
public enum Store {
    public static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Core", isDirectory: true)
    }()

    static func url(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(name), options: [.atomic, .completeFileProtection])
    }
}

@MainActor
public final class Preferences: ObservableObject {
    public static let shared = Preferences()

    @Published public var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            settings.whitelist = Whitelist.normalise(settings.whitelist)
            Store.write(settings, "settings.json")
            for gone in Set(oldValue.whitelist).subtracting(settings.whitelist) {
                Task { await Identity.forget(gone) }
                if !History.shared.knows(host: gone) { Favicons.shared.forget(host: gone) }
            }
            if settings.filterLists != oldValue.filterLists { Blocker.shared.refresh(force: true) }
        }
    }

    private init() {
        settings = Store.read(Settings.self, "settings.json") ?? Settings()
    }

    /// The picture file changed under the same setting.
    @Published public private(set) var newTabImageVersion = 0
    public func newTabImageChanged() { newTabImageVersion += 1 }
}

/// The domains whose jar survives. Each gets a data store of its own on
/// disk and a fingerprint seed that never changes, so a site that is
/// logged in keeps seeing the same machine.
@MainActor
public enum Whitelist {
    public static func normalise(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains.compactMap { raw in
            var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let host = URL(string: d.contains("://") ? d : "https://" + d)?.host { d = host }
            while d.hasPrefix(".") { d.removeFirst() }
            guard !d.isEmpty, seen.insert(d).inserted else { return nil }
            return d
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

    static func storeID(for domain: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("core.jar." + domain).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Random the first time, then fixed for as long as the domain stays.
    static func seed(for domain: String) -> UInt64 {
        var seeds = Store.read([String: UInt64].self, "seeds.json") ?? [:]
        if let seed = seeds[domain] { return seed }
        let seed = UInt64.random(in: .min ... .max)
        seeds[domain] = seed
        Store.write(seeds, "seeds.json")
        return seed
    }
}
