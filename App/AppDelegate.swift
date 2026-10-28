import AppKit
import BrowserKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceWatcher: AnyCancellable?
    private(set) var browser: BrowserWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceWatcher = Preferences.shared.$settings
            .map(\.appearance)
            .removeDuplicates()
            .sink { appearance in
                NSApp.appearance = switch appearance {
                case .system: nil
                case .light: NSAppearance(named: .aqua)
                case .dark: NSAppearance(named: .darkAqua)
                }
            }
        Blocker.shared.start()
        browser = BrowserWindowController()
        NSApp.mainMenu = Menus.build(target: self, browser: browser)
        Extensions.shared.host = browser
        Extensions.shared.windowOpened()
        Extensions.shared.start()
        #if DEBUG
        SelfTest.run(browser)
        SelfTest.probe(browser)
        #endif
        browser.restore()
        browser.showWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        browser?.saveTabs()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "http" || url.scheme == "https" {
            browser?.open(url)
        }
    }

    @objc func showSettings(_ sender: Any?) { browser?.showSettings(sender) }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Browser",
            .credits: NSAttributedString(
                string: "Browser's own WebKit.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }
}
