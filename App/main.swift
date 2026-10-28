import AppKit
import CoreKit

// Pages see en-US whatever the Mac is set to. The patched engine enforces
// it too; this keeps the shell and the engine telling the same story.
UserDefaults.standard.set(["en-US"], forKey: "AppleLanguages")
UserDefaults.standard.set("en_US", forKey: "AppleLocale")
// Smooth scrolling for wheels and keys, as Safari has; WebKit reads this.
UserDefaults.standard.set(true, forKey: "NSScrollAnimationEnabled")

#if DEBUG
// Debug builds only: a separate store, so a test instance never touches the
// tabs, history or settings of the Core someone is using.
if let path = UserDefaults.standard.string(forKey: "coreStore") {
    Store.directory = URL(fileURLWithPath: path, isDirectory: true)
}
#endif

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
