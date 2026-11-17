import AppKit
import BrowserKit

/// What the window does with clicks and keys before any view sees them.
extension BrowserWindowController {
    func watchEvents() {
        monitors = [
            EventMonitor([.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.leaveFields(for: event) ?? false
            },
            // A mouse's back and forward buttons do what ⌘[ and ⌘] do. WebKit
            // would otherwise take them for its own lists, which a wipe empties.
            EventMonitor([.otherMouseDown, .otherMouseUp]) { [weak self] event in
                guard let self, event.window === window, event.buttonNumber == 3 || event.buttonNumber == 4 else { return false }
                if event.type == .otherMouseDown { mouseButton(event.buttonNumber) }
                return true
            },
            // ⇧⌘/ is macOS's own "search the Help menu"; in Browser it opens
            // about://help, before the system can take it.
            EventMonitor(.keyDown) { [weak self] event in
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
                guard let self, event.window === window, modifiers == [.command, .shift],
                      event.charactersIgnoringModifiers == "/" || event.charactersIgnoringModifiers == "?" || event.keyCode == 44
                else { return false }
                show(.help)
                return true
            },
        ]
    }

    /// Button 3 is back, button 4 forward.
    func mouseButton(_ number: Int) {
        if number == 3 { browser.selected?.goBack() } else { browser.selected?.goForward() }
    }

    /// A click anywhere but the field, while editing it, leaves it: on the
    /// page, focus goes to the page; elsewhere, to nothing. True if the
    /// click stops here.
    private func leaveFields(for event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let field = sidebar.addressField
        let inside = field.contains(event)
        // The first click on the field focuses it with everything
        // selected, as Safari's does; later clicks place the caret.
        if inside, !field.isEditing, event.type == .leftMouseDown {
            field.focus()
            return true
        }
        // Any other field being typed in (Settings' add rows, the
        // find bar) lets go when the click lands outside it.
        if !field.isEditing, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let edited = editor.delegate as? NSView, !edited.contains(event) {
            window.makeFirstResponder(nil)
            return false
        }
        let list = field.suggestions
        guard field.isEditing, !inside, !(list.isShown && list.contains(event)) else { return false }
        if let web = browser.selected?.webView, web.superview != nil, web.contains(event) {
            window.makeFirstResponder(web)
        } else {
            window.makeFirstResponder(nil)
        }
        return false
    }
}
