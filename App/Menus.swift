import AppKit

/// The menu bar. Safari's shortcuts where Browser has the feature, plus ⌘I for Persist.
@MainActor
enum Menus {
    static func build(target app: AppDelegate, browser: BrowserWindowController) -> NSMenu {
        let main = NSMenu()
        defer { aim(main, at: browser) }

        main.addItem(submenu("Browser", [
            item("About Browser", #selector(AppDelegate.showAbout(_:)), "", target: app),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: app),
            .separator(),
            item("Hide Browser", #selector(NSApplication.hide(_:)), ""),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), ""),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Browser", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("File", [
            item("New Tab", #selector(BrowserWindowController.newTabAction(_:)), "t"),
            item("Open Location…", #selector(BrowserWindowController.focusAddress(_:)), "l"),
            item("Save Page As…", #selector(BrowserWindowController.savePage(_:)), "s", [.command, .shift]),
            .separator(),
            item("Close Tab", #selector(BrowserWindowController.closeTabAction(_:)), "w"),
            item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift]),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Go", #selector(BrowserWindowController.pasteAndGo(_:)), "v", [.command, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(BrowserWindowController.showFind(_:)), "f"),
            item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g"),
            item("Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "g", [.command, .shift]),
        ]))

        main.addItem(submenu("View", [
            item("Reload Page", #selector(BrowserWindowController.reloadAction(_:)), "r"),
            item("Stop", #selector(BrowserWindowController.stopAction(_:)), "."),
            .separator(),
            item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"),
            item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"),
            .separator(),
            item("Hide Sidebar", #selector(BrowserWindowController.toggleBrowserSidebar(_:)), "s"),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            .separator(),
            item("Web Inspector", #selector(BrowserWindowController.showInspector(_:)), "i", [.command, .shift]),
        ]))

        main.addItem(submenu("History", [
            item("Back", #selector(BrowserWindowController.goBack(_:)), "["),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"),
            .separator(),
            item("Show All History", #selector(BrowserWindowController.showHistory(_:)), "h"),
            item("Downloads", #selector(BrowserWindowController.showDownloads(_:)), "j"),
        ]))

        var tabItems: [NSMenuItem] = [
            item("Persist Tab", #selector(BrowserWindowController.togglePersist(_:)), "i"),
            .separator(),
            item("Next Tab", #selector(BrowserWindowController.nextTab(_:)), "]", [.command, .shift]),
            item("Previous Tab", #selector(BrowserWindowController.previousTab(_:)), "[", [.command, .shift]),
            .separator(),
            item("Copy Address", #selector(BrowserWindowController.copyAddress(_:)), "c", [.command, .shift]),
            item("Duplicate Tab", #selector(BrowserWindowController.duplicateTab(_:)), "d"),
            .separator(),
        ]
        // The same two commands on other keys: ⌃Tab, ⌃⇧Tab, and ⇧⌘↓, ⇧⌘↑
        // (going round from the last tab to the first, as all of them do).
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        for (key, mods, next) in [("\t", NSEvent.ModifierFlags.control, true), ("\t", [.control, .shift], false),
                                  (down, [.command, .shift], true), (up, [.command, .shift], false)] {
            let extra = item(next ? "Next Tab" : "Previous Tab",
                             next ? #selector(BrowserWindowController.nextTab(_:)) : #selector(BrowserWindowController.previousTab(_:)), key, mods)
            extra.isHidden = true
            extra.allowsKeyEquivalentWhenHidden = true
            tabItems.insert(extra, at: 4)
        }
        for n in 1 ... 9 {
            let jump = item("Tab \(n)", #selector(BrowserWindowController.selectTabNumber(_:)), "\(n)")
            jump.tag = n
            tabItems.append(jump)
        }
        main.addItem(submenu("Tab", tabItems))

        main.addItem(submenu("Help", [
            item("Keyboard Shortcuts", #selector(BrowserWindowController.showHelp(_:)), "/", [.command, .shift]),
        ]))
        return main
    }

    /// Every shortcut in the menus, for about://help: [menu, item, keys].
    /// A command with several keys is one row.
    static func shortcuts(in main: NSMenu) -> [[String]] {
        var rows: [[String]] = []
        var seen: [String: Int] = [:]
        for top in main.items {
            guard let menu = top.submenu else { continue }
            // Not the ones macOS adds to every Edit menu.
            let system: Set<Selector?> = [Selector(("startDictation:")), Selector(("orderFrontCharacterPalette:"))]
            for item in menu.items where !item.keyEquivalent.isEmpty && !system.contains(item.action)
                && !item.keyEquivalentModifierMask.contains(.function) {
                let keys = describe(item)
                let id = menu.title + item.title
                if let i = seen[id] { rows[i][2] += " or " + keys; continue }
                seen[id] = rows.count
                rows.append([menu.title, item.title, keys])
            }
        }
        return rows
    }

    static func describe(_ item: NSMenuItem) -> String {
        var key = item.keyEquivalent
        var mods = item.keyEquivalentModifierMask
        if key.count == 1, let c = key.first, c.isUppercase { mods.insert(.shift); key = key.lowercased() }
        let shifted: [String: String] = ["{": "[", "}": "]", "_": "-", "?": "/"]
        if let base = shifted[key] { mods.insert(.shift); key = base }
        let names: [String: String] = [
            "\t": "⇥", "\r": "↩", " ": "Space",
            String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): "↑", String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): "↓",
            String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): "←", String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): "→",
        ]
        var text = ""
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        return text + (names[key] ?? key.uppercased())
    }

    /// Browser commands go straight to the browser, not up the responder
    /// chain: there, NSWindow's own toggleSidebar: and a web view that keeps
    /// ⌘-keys can each get in the way, and nothing at all answers while
    /// the window isn't key.
    static func aim(_ menu: NSMenu, at browser: BrowserWindowController) {
        for item in menu.items {
            if let sub = item.submenu { aim(sub, at: browser) }
            if item.target == nil, let action = item.action, browser.responds(to: action) {
                item.target = browser
            }
        }
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        holder.submenu = menu
        return holder
    }

    static func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        // A shifted shortcut is written as the shifted character (⇧⌘S is
        // "S"); a lowercase key with a shift mask also matches plain ⌘S.
        var key = key
        var mods = mods
        if mods.contains(.shift), key.count == 1, let c = key.first, c.isLetter || "[]=-/".contains(c) {
            let shifted: [String: String] = ["[": "{", "]": "}", "=": "+", "-": "_", "/": "?"]
            key = shifted[key] ?? key.uppercased()
            mods.remove(.shift)
        }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        item.target = target
        return item
    }
}
