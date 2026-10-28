import AppKit
import Darwin
import CoreKit

// No AppKit window, store, extension or network request before this check.
MainActor.assumeIsolated { Engine.requirePatched() }
if CommandLine.arguments.contains("--check-engine") {
    print("Core's patched WebKit verified.")
    exit(EXIT_SUCCESS)
}

// Pages see en-US whatever the Mac is set to. The patched engine enforces
// it too; this keeps the shell and the engine telling the same story.
UserDefaults.standard.set(["en-US"], forKey: "AppleLanguages")
UserDefaults.standard.set("en_US", forKey: "AppleLocale")

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
