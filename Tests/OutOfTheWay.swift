#if DEBUG
import AppKit

/// Debug builds only: `-browserSelfTest YES` runs Browser out of the way of
/// whoever is using this Mac: no Dock icon, never in front, its window all
/// but transparent and clicks going through it. It still draws, as a window
/// someone could see.
@MainActor
enum OutOfTheWay {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "browserSelfTest") }

    /// The window behind whatever is in front, without taking focus.
    static func place(_ shell: BrowserWindowController) {
        guard let window = shell.window else { return }
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.orderBack(nil)
    }
}
#endif
