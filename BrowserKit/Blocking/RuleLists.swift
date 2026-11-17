import Foundation
import WebKit

/// The compiled content rule lists: WebKit's store of them on disk, the
/// ones in force, and every tab's content controller they are in force in.
@MainActor
final class RuleLists {
    private let store: WKContentRuleListStore?
    private var lists: [WKContentRuleList] = []
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    private static let baseID = "browser-base"
    private static func filtersID(_ number: Int) -> String { "browser-filters-\(number)" }

    /// How many lists the filter lists last compiled into.
    private var filtersCount: Int {
        get { Store.read(Int.self, "filters-lists.json") ?? 0 }
        set { Store.write(newValue, "filters-lists.json") }
    }

    init() {
        let folder = Store.url("Rules")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: folder)
    }

    /// A content controller with every list in force, and every list that
    /// comes into force later.
    func controller() -> WKUserContentController {
        let controller = WKUserContentController()
        lists.forEach(controller.add)
        controllers.add(controller)
        return controller
    }

    /// At launch: the built-in list, then the filter lists as they were
    /// last compiled, with nothing fetched.
    func load() async {
        if let json = try? ContentRule.encode(BaseList.rules),
           let base = try? await store?.compileContentRuleList(forIdentifier: RuleLists.baseID, encodedContentRuleList: json) {
            install(base)
        }
        let count = filtersCount
        for number in 0 ..< count {
            if let list = try? await store?.contentRuleList(forIdentifier: RuleLists.filtersID(number)) { install(list) }
        }
        await removeStale(keeping: count)
    }

    /// Puts newly compiled filter lists, each as its JSON, in place of the
    /// ones in force.
    func replaceFilters(with encoded: [String]) async throws {
        guard let store else { return }
        var compiled: [WKContentRuleList] = []
        for (number, json) in encoded.enumerated() {
            if let list = try await store.compileContentRuleList(forIdentifier: RuleLists.filtersID(number), encodedContentRuleList: json) {
                compiled.append(list)
            }
        }
        // Swap the whole set at once, and drop lists the new set no
        // longer has.
        for number in encoded.count ..< max(encoded.count, filtersCount) {
            remove(RuleLists.filtersID(number))
            try? await store.removeContentRuleList(forIdentifier: RuleLists.filtersID(number))
        }
        compiled.forEach(install)
        filtersCount = encoded.count
    }

    private func install(_ list: WKContentRuleList) {
        remove(list.identifier)
        controllers.allObjects.forEach { $0.add(list) }
        lists.append(list)
    }

    private func remove(_ identifier: String) {
        for old in lists where old.identifier == identifier {
            controllers.allObjects.forEach { $0.remove(old) }
        }
        lists.removeAll { $0.identifier == identifier }
    }

    /// Compiled lists from an older set, or an older name, take up disk.
    private func removeStale(keeping count: Int) async {
        guard let store else { return }
        let current = Set([RuleLists.baseID] + (0 ..< count).map(RuleLists.filtersID))
        for identifier in await store.availableIdentifiers() ?? [] where !current.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }
}
