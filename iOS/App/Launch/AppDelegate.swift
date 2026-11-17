import BrowserKit
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, willFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before WebKit starts a process: every web process reads these, so
        // navigator.language, Accept-Language and Intl all say en-US.
        UserDefaults.standard.set(["en-US"], forKey: "AppleLanguages")
        UserDefaults.standard.set("en_US", forKey: "AppleLocale")
        Blocker.shared.start()
        Userscripts.shared.start()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Userscripts.shared.flush()
    }
}
