import AppKit

/// The menu bar. Safari's shortcuts where Browser has the feature, plus ⌘I for Persist.
@MainActor
enum Menus {
    static func build(app: AppDelegate, commands: Commands) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Browser", [
            item("About Browser", #selector(AppDelegate.showAbout(_:)), "", target: app),
            .separator(),
            item("Settings…", #selector(Commands.showSettings(_:)), ","),
            item("Userscripts", #selector(Commands.showUserscripts(_:)), ""),
            .separator(),
            item("Hide Browser", #selector(NSApplication.hide(_:)), ""),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), ""),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Browser", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("File", [
            item("New Tab", #selector(Commands.newTab(_:)), "t"),
            item("Open Location…", #selector(Commands.focusAddress(_:)), "l"),
            item("Save Page As…", #selector(Commands.savePage(_:)), "s", [.command, .shift]),
            .separator(),
            item("Close Tab", #selector(Commands.closeTab(_:)), "w"),
            item("Reopen Closed Tab", #selector(Commands.reopenClosedTab(_:)), "t", [.command, .shift]),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Go", #selector(Commands.pasteAndGo(_:)), "v", [.command, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(Commands.showFind(_:)), "f"),
            item("Find Next", #selector(Commands.findNext(_:)), "g"),
            item("Find Previous", #selector(Commands.findPrevious(_:)), "g", [.command, .shift]),
        ]))

        main.addItem(submenu("View", [
            item("Reload Page", #selector(Commands.reload(_:)), "r"),
            item("Stop", #selector(Commands.stop(_:)), "."),
            .separator(),
            item("Actual Size", #selector(Commands.actualSize(_:)), "0"),
            item("Zoom In", #selector(Commands.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(Commands.zoomOut(_:)), "-"),
            .separator(),
            item("Hide Sidebar", #selector(Commands.toggleBrowserSidebar(_:)), "s"),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            .separator(),
            item("Web Inspector", #selector(Commands.toggleInspector(_:)), "i", [.command, .shift]),
        ]))

        main.addItem(submenu("History", [
            item("Back", #selector(Commands.goBack(_:)), "["),
            item("Forward", #selector(Commands.goForward(_:)), "]"),
            .separator(),
            item("Show All History", #selector(Commands.showHistory(_:)), "h"),
            item("Downloads", #selector(Commands.showDownloads(_:)), "j"),
        ]))

        main.addItem(submenu("Tab", [
            item("Persist Tab", #selector(Commands.togglePersist(_:)), "i"),
            .separator(),
            item("Next Tab", #selector(Commands.nextTab(_:)), "]", [.command, .shift]),
            item("Previous Tab", #selector(Commands.previousTab(_:)), "[", [.command, .shift]),
        ] + otherTabKeys() + [
            .separator(),
            item("Copy Address", #selector(Commands.copyAddress(_:)), "c", [.command, .shift]),
            item("Duplicate Tab", #selector(Commands.duplicateTab(_:)), "d"),
            .separator(),
        ] + (1 ... 9).map { number in
            let jump = item("Tab \(number)", #selector(Commands.selectTabNumber(_:)), "\(number)")
            jump.tag = number
            return jump
        }))

        main.addItem(submenu("Help", [
            item("Keyboard Shortcuts", #selector(Commands.showHelp(_:)), "/", [.command, .shift]),
        ]))
        aim(main, at: commands)
        return main
    }

    /// Next Tab and Previous Tab on other keys: ⇧⌘↓, ⇧⌘↑, and ⌃Tab, ⌃⇧Tab
    /// (going round from the last tab to the first, as all of them do).
    /// Unseen items, so the keys work and about://help lists them.
    private static func otherTabKeys() -> [NSMenuItem] {
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let keys: [(String, NSEvent.ModifierFlags, Bool)] = [
            (up, [.command, .shift], false), (down, [.command, .shift], true),
            ("\t", [.control, .shift], false), ("\t", .control, true),
        ]
        return keys.map { key, modifiers, next in
            let extra = item(next ? "Next Tab" : "Previous Tab",
                             next ? #selector(Commands.nextTab(_:)) : #selector(Commands.previousTab(_:)), key, modifiers)
            extra.isHidden = true
            extra.allowsKeyEquivalentWhenHidden = true
            return extra
        }
    }

    /// Browser commands go straight to `commands`, not up the responder
    /// chain: there, NSWindow's own toggleSidebar: and a web view that keeps
    /// ⌘-keys can each get in the way, and nothing at all answers while
    /// the window isn't key.
    private static func aim(_ menu: NSMenu, at commands: Commands) {
        for item in menu.items {
            if let submenu = item.submenu { aim(submenu, at: commands) }
            if item.target == nil, let action = item.action, commands.responds(to: action) {
                item.target = commands
            }
        }
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        // A shifted shortcut is written as the shifted character (⇧⌘S is
        // "S"); a lowercase key with a shift mask also matches plain ⌘S.
        var key = key
        var modifiers = modifiers
        if modifiers.contains(.shift), key.count == 1, let character = key.first, character.isLetter || "[]=-/".contains(character) {
            let shifted: [String: String] = ["[": "{", "]": "}", "=": "+", "-": "_", "/": "?"]
            key = shifted[key] ?? key.uppercased()
            modifiers.remove(.shift)
        }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }
}
