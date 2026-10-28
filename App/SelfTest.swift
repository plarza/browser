#if DEBUG
import AppKit
import CoreKit
import WebKit

/// Debug builds only: `-coreSelfTest YES` drives the real window with real
/// key and mouse events, through AppKit's own dispatch (menus, responders,
/// field editors), and logs PASS or FAIL for each thing a person would do.
@MainActor
enum SelfTest {
    static func run(_ browser: BrowserWindowController) {
        guard UserDefaults.standard.bool(forKey: "coreSelfTest"), let window = browser.window else { return }
        Task { @MainActor in
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            browser.open(URL(string: "https://en.wikipedia.org/wiki/WebKit")!)
            try? await Task.sleep(for: .seconds(4))
            for _ in 0 ..< 20 where !window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(250))
            }

            // Clicking the address field once selects the whole address.
            click(browser.addressFieldForTesting, in: window)
            try? await Task.sleep(for: .milliseconds(300))
            let editor = window.firstResponder as? NSTextView
            let text = editor?.string ?? ""
            let range = editor?.selectedRange() ?? NSRange()
            check("click selects the whole address", editor != nil && text.hasPrefix("https://") && range.location == 0 && range.length == (text as NSString).length,
                  "text=\(text) selection=\(range)")

            // Clicking the page leaves the field.
            click(browser.selectedWebViewForTesting, in: window)
            try? await Task.sleep(for: .milliseconds(300))
            check("click on the page leaves the field", !(window.firstResponder is NSTextView) && !browser.addressFieldForTesting.isEditing,
                  "firstResponder=\(String(describing: window.firstResponder))")

            // ⌘L selects everything, and a click on the page leaves again.
            key("l", in: window)
            try? await Task.sleep(for: .milliseconds(300))
            let lEditor = window.firstResponder as? NSTextView
            check("⌘L selects the whole address", lEditor != nil && lEditor!.selectedRange().length == (lEditor!.string as NSString).length && lEditor!.string.hasPrefix("https://"),
                  "firstResponder=\(String(describing: window.firstResponder))")
            click(browser.selectedWebViewForTesting, in: window)
            try? await Task.sleep(for: .milliseconds(300))
            check("click on the page after ⌘L leaves the field", !(window.firstResponder is NSTextView),
                  "firstResponder=\(String(describing: window.firstResponder))")

            // ⌘S hides the sidebar with the page focused, and shows it again.
            window.makeFirstResponder(browser.selectedWebViewForTesting)
            let before = browser.sidebarShownForTesting
            key("s", in: window)
            try? await Task.sleep(for: .milliseconds(600))
            check("⌘S hides the sidebar", before && !browser.sidebarShownForTesting, "before=\(before) after=\(browser.sidebarShownForTesting)")
            key("s", in: window)
            try? await Task.sleep(for: .milliseconds(600))
            check("⌘S shows it again", browser.sidebarShownForTesting, "after=\(browser.sidebarShownForTesting)")

            // Favicon: the tab has one once the page has loaded.
            for _ in 0 ..< 20 where browser.selectedTab.flatMap({ Favicons.shared.icon(for: $0.url) }) == nil {
                try? await Task.sleep(for: .milliseconds(500))
            }
            check("the tab shows the site's icon", browser.selectedTab.flatMap { Favicons.shared.icon(for: $0.url) } != nil, "")

            NSLog("Core self-test: done")
        }
    }

    static func check(_ name: String, _ ok: Bool, _ detail: String) {
        NSLog("Core self-test: \(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — \(detail)")")
    }

    static func click(_ view: NSView, in window: NSWindow) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // The up goes in the queue first, for the tracking loop the down starts.
        // Straight to the window, as AppKit routes a click in the key window
        // (macOS won't make a test window key while someone works elsewhere).
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        NSApp.sendEvent(mouse(.leftMouseDown))
    }

    static func key(_ character: String, in window: NSWindow, modifiers: NSEvent.ModifierFlags = .command) {
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                                    isARepeat: false, keyCode: character == "s" ? 1 : character == "l" ? 37 : 0)!
        // What NSApp does with a ⌘-key for the key window.
        if !window.performKeyEquivalent(with: down) { window.sendEvent(down) }
    }
}
#endif
