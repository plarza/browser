import AppKit
import BrowserKit
import WebKit

/// What only the window can answer for BrowserKit: where the keyboard goes
/// after a wipe, every dialog and panel a page asks for, and extensions'
/// popups.
extension BrowserWindowController: Shell {
    func tab(_ tab: Tab, didReplace old: WKWebView?) {
        // The page showing keeps the keyboard across a wipe.
        if tab === browser.selected, tab.webView.window === window { window?.makeFirstResponder(tab.webView) }
    }

    /// Closing a Persist tab deletes its jar, logins and all, so a person
    /// closing one is asked first.
    func confirmClosing(_ tab: Tab) async -> Bool {
        let name = tab.title.isEmpty ? tab.url?.host ?? "this tab" : tab.title
        return await Dialogs.ask("Close “\(name)”?", detail: "Its cookies and site data will be deleted.", yes: "Close Tab")
    }

    func bringForward(_ tab: Tab) {
        #if DEBUG
        if OutOfTheWay.enabled { return }
        #endif
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func tab(_ tab: Tab, allowCapture type: WKMediaCaptureType, for origin: String) async -> Bool {
        let what = switch type {
        case .camera: "your camera"
        case .microphone: "your microphone"
        default: "your camera and microphone"
        }
        return await Dialogs.ask("Allow \(origin) to use \(what)?", yes: "Allow", no: "Don't Allow")
    }

    func tab(_ tab: Tab, saveDownload name: String) async -> URL? {
        #if DEBUG
        // Tooling can't answer a save panel: its downloads go into its own store.
        if OutOfTheWay.enabled, let store = UserDefaults.standard.string(forKey: "browserStore") {
            return URL(fileURLWithPath: store, isDirectory: true).appending(path: name)
        }
        #endif
        guard let window else { return nil }
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }

    func tab(_ tab: Tab, runAlert message: String) async {
        _ = await Dialogs.ask(tab.url?.host ?? "This page", detail: message, yes: "OK", no: nil)
    }

    func tab(_ tab: Tab, runConfirm message: String) async -> Bool {
        await Dialogs.ask(tab.url?.host ?? "This page", detail: message, yes: "OK")
    }

    func tab(_ tab: Tab, runPrompt message: String, defaultText: String?) async -> String? {
        await Dialogs.prompt(tab.url?.host ?? "This page", detail: message, text: defaultText ?? "")
    }

    func tab(_ tab: Tab, chooseFiles multiple: Bool, directories: Bool) async -> [URL]? {
        guard let window else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = directories
        panel.canChooseFiles = true
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    /// An extension's popup, under its button: fitted to its contents by
    /// WebKit, on an opaque background unless the extension draws its own.
    func present(_ action: WKWebExtension.Action) {
        guard let popover = action.popupPopover else { return }
        action.popupWebView?.underPageBackgroundColor = .white
        action.popupWebView?.setValue(true, forKey: "drawsBackground")
        self.popover?.close()
        let anchor = sidebar.actionBar.anchor ?? sidebar.actionBar
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        self.popover = popover
    }

    var windowFrame: CGRect { window?.frame ?? .zero }
}
