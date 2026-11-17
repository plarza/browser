import AppKit

/// A keyboard shortcut as about://help lists it: read from the menus, so
/// the page can't fall out of step with them.
struct Shortcut: Hashable {
    /// The menu it is in.
    let menu: String
    let title: String
    /// "⇧⌘T"; several keys for one command are "⌃⇥ or ⇧⌘↓".
    var keys: String

    /// Every shortcut in the menus, in their order. A command with several
    /// keys is one shortcut.
    @MainActor
    static func all(in main: NSMenu) -> [Shortcut] {
        var found: [Shortcut] = []
        var places: [String: Int] = [:]
        // Not the ones macOS adds to every Edit menu.
        let system: Set<Selector?> = [Selector(("startDictation:")), #selector(NSApplication.orderFrontCharacterPalette(_:))]
        for top in main.items {
            guard let menu = top.submenu else { continue }
            for item in menu.items where !item.keyEquivalent.isEmpty && !system.contains(item.action)
                && !item.keyEquivalentModifierMask.contains(.function) {
                let id = menu.title + item.title
                if let place = places[id] {
                    found[place].keys += " or " + keys(of: item)
                } else {
                    places[id] = found.count
                    found.append(Shortcut(menu: menu.title, title: item.title, keys: keys(of: item)))
                }
            }
        }
        return found
    }

    /// The keys of the menu item that does `action`, or "" if it has none.
    @MainActor
    static func keys(for action: Selector, in main: NSMenu) -> String {
        main.items.compactMap(\.submenu).flatMap(\.items)
            .filter { $0.action == action && !$0.keyEquivalent.isEmpty }
            .map(keys(of:)).joined(separator: " or ")
    }

    /// A menu item's keys, as the menu draws them.
    @MainActor
    static func keys(of item: NSMenuItem) -> String {
        var key = item.keyEquivalent
        var modifiers = item.keyEquivalentModifierMask
        if key.count == 1, let character = key.first, character.isUppercase {
            modifiers.insert(.shift)
            key = key.lowercased()
        }
        let shifted: [String: String] = ["{": "[", "}": "]", "_": "-", "?": "/"]
        if let base = shifted[key] {
            modifiers.insert(.shift)
            key = base
        }
        let names: [String: String] = [
            "\t": "⇥", "\r": "↩", " ": "Space",
            String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): "↑", String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): "↓",
            String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): "←", String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): "→",
        ]
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (names[key] ?? key.uppercased())
    }
}
