#if DEBUG
import BrowserKit
import SwiftUI

/// Debug builds only: launch arguments that open pages and put the app in
/// one state, for screenshots from the simulator.
///
///   -browserOpen "https://a,https://b"   tabs to open, the last one showing
///   -browserPersist N                    tab N (from 0) on Persist
///   -browserState grid|reopen|editing|newtab|settings|collapsed|swipe|swipeend|back
///   -browserType text                    typed into the address sheet
@MainActor
enum Shots {
    static var typed: String? { UserDefaults.standard.string(forKey: "browserType") }

    static func run(_ browser: Browser) {
        let defaults = UserDefaults.standard
        guard let open = defaults.string(forKey: "browserOpen") else { return }
        for tab in browser.tabs { browser.close(tab) }
        browser.showPage()
        for url in open.split(separator: ",").compactMap({ URL(string: String($0)) }) { browser.newTab(url) }
        if defaults.object(forKey: "browserPersist") != nil {
            let i = defaults.integer(forKey: "browserPersist")
            if browser.tabs.indices.contains(i) { browser.tabs[i].persist = true }
        }
        guard let state = defaults.string(forKey: "browserState") else { return }
        Task {
            // Each tab in turn, so the grid has a picture of every one.
            for tab in browser.tabs {
                browser.select(tab)
                try? await Task.sleep(for: .seconds(3))
            }
            switch state {
            case "grid": browser.showGrid()
            case "reopen":
                browser.showGrid()
                try? await Task.sleep(for: .seconds(2))
                browser.showPage(browser.tabs[min(1, browser.tabs.count - 1)])
            case "editing": browser.edit(.current)
            case "newtab": browser.edit(.newTab)
            case "settings": browser.showGrid(); browser.showingSettings = true
            case "collapsed": browser.barCollapsed = true
            case "swipeend":
                // A finger flicking left from the first tab, then letting go.
                browser.select(browser.tabs[0])
                try? await Task.sleep(for: .seconds(2))
                if let tab = browser.selected { browser.capture(tab) }
                for x in stride(from: 0.0, through: -160, by: -8) {
                    browser.pageOffset = x
                    try? await Task.sleep(for: .milliseconds(16 * Int(Motion.slow)))
                }
                browser.endSwipe(translation: -160, velocity: -900, width: Screen.bounds.width)
                NSLog("pagelog after end offset=%.1f selected=%@", browser.pageOffset, browser.selected?.url?.lastPathComponent ?? "-")
                try? await Task.sleep(for: .seconds(3))
                NSLog("pagelog later offset=%.1f selected=%@", browser.pageOffset, browser.selected?.url?.lastPathComponent ?? "-")
            case "back":
                // A second page in the same tab, then a finger from the
                // left edge, past a third of the way, letting go.
                guard let tab = browser.selected, browser.tabs.count > 1, let url = browser.tabs[0].url else { break }
                tab.load(url)
                try? await Task.sleep(for: .seconds(4))
                let pages = browser.stage.pages
                pages.beginSwipe(back: true)
                for x in stride(from: 0.0, through: 160, by: 6) {
                    pages.follow(x)
                    try? await Task.sleep(for: .milliseconds(16 * Int(Motion.slow)))
                }
                pages.endSwipe(at: 160, speed: 900)
            case "snap":
                if let tab = browser.selected {
                    browser.capture(tab)
                    try? browser.picture(tab)?.pngData()?.write(to: URL.temporaryDirectory.appending(path: "snap.png"))
                }
            case "swipe": browser.select(browser.tabs[0]); try? await Task.sleep(for: .seconds(1)); if let tab = browser.selected { browser.capture(tab) }; browser.pageOffset = -170
            default: break
            }
        }
    }
}
#endif
