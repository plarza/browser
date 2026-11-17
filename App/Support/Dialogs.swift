import AppKit
import BrowserKit

/// Every dialog in Browser, as a sheet on the window: Return answers yes,
/// Escape answers no (or dismisses an alert that has only OK).
@MainActor
enum Dialogs {
    /// Browser's one window, which every dialog is a sheet on.
    static weak var window: NSWindow?

    static func ask(_ message: String, detail: String = "", yes: String, no: String? = "Cancel", field: NSTextField? = nil) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: yes)
        if let no { alert.addButton(withTitle: no).keyEquivalent = "\u{1b}" }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // AppKit gives an OK-only alert no Escape: an unseen button that presses OK.
        if no == nil {
            let escape = NSButton(title: "", target: alert.buttons[0], action: #selector(NSButton.performClick(_:)))
            escape.keyEquivalent = "\u{1b}"
            escape.frame = .zero
            alert.accessoryView = NSView(frame: .zero)
            alert.accessoryView?.addSubview(escape)
        }
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    static func prompt(_ message: String, detail: String, text: String) async -> String? {
        let field = NSTextField(string: text)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        return await ask(message, detail: detail, yes: "OK", no: "Cancel", field: field) ? field.stringValue : nil
    }

    /// Cancelling deletes what's been downloaded so far, so it asks first.
    static func cancelDownload(_ item: Downloads.Item) async {
        guard item.state == .active,
              await ask("Cancel “\(item.name)”?", yes: "Cancel Download", no: "Keep Downloading"),
              item.state == .active else { return }
        Downloads.shared.cancel(item)
    }
}
