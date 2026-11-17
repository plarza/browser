#if DEBUG
import AppKit
import BrowserKit

/// Debug builds only: `-browserScreenshot <file.png> -browserScreenshotTabs
/// <url,url,…>` (see release/screenshot.sh): the tabs opened and loaded
/// from the internet, a blank tab in front showing the new tab page, the
/// window written to the file, then Browser quits.
@MainActor
enum Screenshot {
    static var file: URL? {
        UserDefaults.standard.string(forKey: "browserScreenshot").map { URL(fileURLWithPath: $0) }
    }

    static func run(_ shell: BrowserWindowController) {
        let defaults = UserDefaults.standard
        guard let file else { return }
        let urls = (defaults.string(forKey: "browserScreenshotTabs") ?? "").split(separator: ",").compactMap { URL(string: String($0)) }
        if let appearance = defaults.string(forKey: "browserScreenshotAppearance").flatMap(Settings.Appearance.init(rawValue:)) {
            Preferences.shared.settings.appearance = appearance
        }
        Preferences.shared.settings.fill = defaults.bool(forKey: "browserScreenshotFill")
        Task {
            guard let window = shell.window else { exit(EXIT_FAILURE) }
            let browser = shell.browser
            window.setContentSize(NSSize(width: 1320, height: 820))
            let first = browser.tabs
            var last: Tab?
            for url in urls { last = browser.newTab(url, after: last ?? first.last, select: false) }
            for tab in first { browser.close(tab) }
            if let persist = defaults.string(forKey: "browserScreenshotPersist").flatMap(URL.init(string:)),
               let tab = browser.tabs.first(where: { $0.url?.host == persist.host }) {
                tab.persist = true
            }
            browser.newTab(after: last)
            let tabs = browser.tabs.filter { $0.url != nil }
            let loaded = await Tooling.until("the tabs to load", seconds: 60) {
                tabs.allSatisfy { !$0.isLoading && !$0.title.isEmpty } && !Favicons.shared.isFetching
            }
            if !loaded { NSLog("Browser screenshot: some tabs hadn't loaded: \(tabs.filter(\.isLoading).compactMap(\.url))") }
            window.makeFirstResponder(nil)
            // The active window, so its buttons are in colour. The plain
            // activate() is only a request, which macOS turns down while
            // the terminal that started the script is in front.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            _ = await Tooling.until("the window to be key", seconds: 5) { window.isKeyWindow }
            let saved = await Shots.draw(window, to: file)
            NSLog("Browser screenshot: \(saved ? "wrote \(file.path)" : "failed")")
            exit(saved ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }
}
#endif
