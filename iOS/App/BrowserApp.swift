import BrowserKit
import SwiftUI

@main
struct BrowserApp: App {
    @State private var browser: Browser
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.scenePhase) private var phase

    init() {
        // en-US for every WebKit process, so navigator.language,
        // Accept-Language and Intl agree; set before WebKit starts one.
        UserDefaults.standard.set(["en-US"], forKey: "AppleLanguages")
        UserDefaults.standard.set("en_US", forKey: "AppleLocale")
        Blocker.shared.start()
        // Opens history.db in the background before the first keystroke needs it.
        _ = History.shared
        let browser = Browser()
        _browser = State(initialValue: browser)
        browser.restore()
        #if DEBUG
        Shots.run(browser)
        #endif
    }

    private var scheme: ColorScheme? {
        switch prefs.settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(browser)
                .preferredColorScheme(scheme)
                .onOpenURL { url in
                    if url.scheme == "http" || url.scheme == "https" { browser.open(url) }
                }
        }
        .onChange(of: phase) { _, phase in
            if phase != .active { browser.saveTabs() }
        }
    }
}
