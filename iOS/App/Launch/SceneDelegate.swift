import BrowserKit
import UIKit

/// The one window: the tabs come back, the screen shows them, and links
/// from other apps open in a new tab.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var screen: ScreenController?
    private var appearance: Observer?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let browser = Browser()
        let screen = ScreenController(browser: browser)
        browser.shell = screen
        browser.restore()
        for link in options.urlContexts.map(\.url) where SceneDelegate.isWeb(link) { browser.open(link) }

        let window = UIWindow(windowScene: scene)
        window.rootViewController = screen
        window.makeKeyAndVisible()
        self.window = window
        self.screen = screen
        // Light, Dark or System, for the whole app.
        appearance = Observer { [weak window] in
            window?.overrideUserInterfaceStyle = switch Preferences.shared.settings.appearance {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
            }
        }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for link in contexts.map(\.url) where SceneDelegate.isWeb(link) { screen?.open(link) }
    }

    /// The open tabs are saved whenever the app leaves the foreground: it
    /// may never run again. Stepping aside for the app switcher counts,
    /// since that is where an app is swiped away.
    func sceneWillResignActive(_ scene: UIScene) {
        keep()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        keep()
    }

    private func keep() {
        screen?.browser.save()
        Userscripts.shared.flush()
    }

    private static func isWeb(_ link: URL) -> Bool {
        link.scheme == "http" || link.scheme == "https"
    }
}
