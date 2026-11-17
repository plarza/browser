import AppKit
import BrowserKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The one window and everything in it.
    private(set) var shell: BrowserWindowController?
    private var appearance: Observer?
    /// Links and files another app sent before the window was up.
    private var waiting: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Light, Dark, or macOS's own, which the app then follows as it changes.
        appearance = Observer {
            NSApp.appearance = switch Preferences.shared.settings.appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
        #if DEBUG
        Tooling.prepare()
        #endif
        Blocker.shared.start()
        Userscripts.shared.start()
        // Opens history.db in the background before the first keystroke needs it.
        _ = History.shared
        let shell = BrowserWindowController()
        self.shell = shell
        NSApp.mainMenu = Menus.build(app: self, commands: shell.commands)
        Extensions.shared.windowOpened()
        Extensions.shared.start()
        #if DEBUG
        SelfTest.start(shell)
        Probe.run(shell)
        #endif
        shell.browser.restore()
        waiting.forEach(shell.open)
        waiting = []
        #if DEBUG
        Screenshot.run(shell)
        // Tooling runs behind whatever is in front, and never takes focus.
        if OutOfTheWay.enabled {
            OutOfTheWay.place(shell)
            return
        }
        #endif
        shell.showWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        shell?.browser.save()
        Userscripts.shared.flush()
    }

    /// Links, and the pages Finder opens with Browser, from other apps.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "http" || url.scheme == "https" || url.isFileURL {
            if let shell { shell.open(url) } else { waiting.append(url) }
        }
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Browser",
            .credits: NSAttributedString(
                string: "Uses macOS WebKit.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }
}
