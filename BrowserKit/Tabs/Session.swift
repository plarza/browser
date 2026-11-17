import Foundation

/// The open tabs' addresses (tabs.json), so they come back after a
/// relaunch, each in a new identity like any other load. A Persist tab's
/// jar is named too, so it comes back in it.
@MainActor
enum Session {
    struct Saved: Codable, Equatable {
        struct Tab: Codable, Equatable {
            var url: URL
            var jar: UUID?
        }

        var tabs: [Tab] = []
        var selected = 0
    }

    private static var last: Saved?

    /// Popups and tabs with nowhere to go are left out; an unchanged list
    /// isn't written again.
    static func save(_ tabs: [Tab], selected: Tab?) {
        let own = tabs.filter { !$0.isPopup && $0.url != nil }
        let saved = Saved(tabs: own.map { Saved.Tab(url: $0.url!, jar: $0.keptIdentity) },
                          selected: own.firstIndex { $0 === selected } ?? 0)
        guard saved != last else { return }
        last = saved
        Store.write(saved, "tabs.json")
    }

    static func restore() -> Saved {
        Store.read(Saved.self, "tabs.json") ?? Saved()
    }
}
