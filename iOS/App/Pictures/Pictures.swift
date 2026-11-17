import BrowserKit
import Observation
import UIKit

/// Pictures of pages, for the grid, the stack and swipes: each tab's
/// current page, and the last few others of its back and forward list.
/// In memory only, never on disk; a closed tab's go with it.
@MainActor @Observable
final class Pictures {
    /// A place in a tab's back and forward list.
    private struct Place: Hashable {
        let tab: UUID
        let index: Int
    }

    private var kept: [Place: (address: URL, image: UIImage)] = [:]
    /// Oldest first.
    @ObservationIgnored private var order: [Place] = []
    /// How many are kept besides each tab's current page.
    private static let others = 12

    /// The page `tab` is on.
    func picture(of tab: Tab) -> UIImage? {
        picture(of: tab, at: tab.backForward.index)
    }

    /// The page at `index` in `tab`'s back and forward list, if the picture
    /// kept for that place is still of the page that is there.
    func picture(of tab: Tab, at index: Int) -> UIImage? {
        let entries = tab.backForward.entries
        guard entries.indices.contains(index), let found = kept[Place(tab: tab.id, index: index)], found.address == entries[index] else { return nil }
        return found.image
    }

    /// `image` is what `tab` shows now. Pictures of closed tabs, and all
    /// but the latest few of pages no tab is on, are let go.
    func keep(_ image: UIImage, of tab: Tab, among tabs: [Tab]) {
        let list = tab.backForward
        guard list.entries.indices.contains(list.index) else { return }
        let place = Place(tab: tab.id, index: list.index)
        kept[place] = (list.entries[list.index], image)
        order.removeAll { $0 == place }
        order.append(place)

        let open = Set(tabs.map(\.id))
        let current = Set(tabs.map { Place(tab: $0.id, index: $0.backForward.index) })
        var spare = order.filter { !current.contains($0) }.count - Pictures.others
        for place in order where !open.contains(place.tab) || (spare > 0 && !current.contains(place)) {
            if open.contains(place.tab) { spare -= 1 }
            kept[place] = nil
        }
        order.removeAll { kept[$0] == nil }
    }

    /// Memory is short: only the pages tabs are on keep their pictures.
    func shed(keeping tabs: [Tab]) {
        let current = Set(tabs.map { Place(tab: $0.id, index: $0.backForward.index) })
        for place in order where !current.contains(place) { kept[place] = nil }
        order.removeAll { kept[$0] == nil }
    }
}
