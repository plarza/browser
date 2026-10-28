import AppKit
import CoreKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var browser: BrowserWindowController!
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Menus.build(target: self)
        Blocker.shared.start()
        browser = BrowserWindowController()
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

    @objc func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindowController() }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Core",
            .credits: NSAttributedString(
                string: Engine.isPatched ? "Core's own WebKit." : "Running on the system WebKit: fingerprint protection is not active in this build.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }
}
