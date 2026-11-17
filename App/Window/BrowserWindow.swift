import AppKit

/// Browser's shortcuts come before the page's: WKWebView takes every ⌘-key
/// it is offered (⌘S, ⌘L…) and hands back only some of them.
final class BrowserWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        // Opaque, except while the desktop shows through (see `isClear`).
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        minSize = NSSize(width: 640, height: 420)
        // Every launch fills the screen, short of the menu bar and Dock; not
        // full screen.
        if let screen = NSScreen.main { setFrame(screen.visibleFrame, display: false) }
        isRestorable = false
    }

    /// Clear only while the Blank new tab page frosts the desktop through
    /// the window. An opaque window's pages and video go to the screen
    /// without being blended with whatever is behind the window, every frame.
    var isClear: Bool {
        get { !isOpaque }
        set {
            guard newValue == isOpaque else { return }
            isOpaque = !newValue
            backgroundColor = newValue ? .clear : .windowBackgroundColor
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘S saves the userscript being edited; anywhere else it hides the sidebar.
        if event.type == .keyDown, let editor = firstResponder as? CodeTextView,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function]) == .command,
           event.charactersIgnoringModifiers == "s" {
            editor.onSave?()
            return true
        }
        if event.type == .keyDown, event.modifierFlags.contains(.command),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
