import AppKit
import BrowserKit

// Set the browsing language before WebKit starts any child processes.
UserDefaults.standard.set(["en-US"], forKey: "AppleLanguages")
UserDefaults.standard.set("en_US", forKey: "AppleLocale")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
#if DEBUG
// Tooling that drives the window is a background app: no Dock icon, never
// in front of what someone is doing.
app.setActivationPolicy(OutOfTheWay.enabled ? .accessory : .regular)
#else
app.setActivationPolicy(.regular)
#endif
app.run()
