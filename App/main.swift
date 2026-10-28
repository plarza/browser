import AppKit
import CoreKit

// Pages see en-US whatever the Mac is set to. The patched engine enforces
// it too; this keeps the shell and the engine telling the same story.
UserDefaults.standard.set(["en-US"], forKey: "AppleLanguages")
UserDefaults.standard.set("en_US", forKey: "AppleLocale")

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
