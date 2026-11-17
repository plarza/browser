import WebKit

/// What BrowserKit asks of the app around it. The shell owns the window:
/// it shows the tabs and the selected tab's `view`, and answers what only
/// something on screen can. Everything else it learns by reading `Browser`
/// and its tabs, which are observable.
@MainActor
public protocol Shell: AnyObject {
    /// The tab shows a new web view: its first, or one a wipe swapped in
    /// for `old`. It arrives here before it loads anything, so the shell
    /// can give it its insets and gestures.
    func tab(_ tab: Tab, didReplace old: WKWebView?)

    /// A person is closing a Persist tab, which deletes its jar, logins and
    /// all: are they sure?
    func confirmClosing(_ tab: Tab) async -> Bool
    /// A userscript granted `window.focus` asked for its tab: bring the
    /// window forward.
    func bringForward(_ tab: Tab)

    /// Camera or microphone; asked every time, never remembered.
    func tab(_ tab: Tab, allowCapture type: WKMediaCaptureType, for origin: String) async -> Bool
    /// Where a download goes, or nil to cancel it.
    func tab(_ tab: Tab, saveDownload name: String) async -> URL?
    func tab(_ tab: Tab, runAlert message: String) async
    func tab(_ tab: Tab, runConfirm message: String) async -> Bool
    func tab(_ tab: Tab, runPrompt message: String, defaultText: String?) async -> String?
    /// The Mac's open panel. The iPhone uses WebKit's own picker.
    func tab(_ tab: Tab, chooseFiles multiple: Bool, directories: Bool) async -> [URL]?

    /// Show an extension's popup, anchored to its button.
    func present(_ action: WKWebExtension.Action)
    /// The window's frame on screen, for extensions that ask.
    var windowFrame: CGRect { get }
}

public extension Shell {
    func bringForward(_ tab: Tab) {}
    func tab(_ tab: Tab, chooseFiles multiple: Bool, directories: Bool) async -> [URL]? { nil }
    func present(_ action: WKWebExtension.Action) {}
    var windowFrame: CGRect { .null }
}
