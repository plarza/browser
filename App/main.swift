import AppKit
import BrowserKit

// Set the browsing language before WebKit starts any child processes.
UserDefaults.standard.set(["en-US"], forKey: "AppleLanguages")
UserDefaults.standard.set("en_US", forKey: "AppleLocale")

#if DEBUG
// Debug builds only: a separate store, so a test instance never touches the
// tabs, history or settings of the Browser someone is using.
if let path = UserDefaults.standard.string(forKey: "browserStore") {
    Store.directory = URL(fileURLWithPath: path, isDirectory: true)
}
#endif

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
