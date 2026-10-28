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
            }
            if settings.filterLists != oldValue.filterLists { Blocker.shared.refresh(force: true) }
        }
    }

    private init() {
        settings = Store.read(Settings.self, "settings.json") ?? Settings()
    }
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
