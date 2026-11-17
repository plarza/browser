#if DEBUG
import AppKit

/// Keys and the mouse, as a person's reach the window: through NSApp and
/// the window's own dispatch, so menus, responders, field editors and the
/// shell's event monitors all take their part.
extension SelfTest {
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func keyDown(_ characters: String, ignoringModifiers: String? = nil, modifiers: NSEvent.ModifierFlags = [], code: UInt16 = 0,
                         in target: NSWindow? = nil, type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: (target ?? window).windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: false, keyCode: code)!
    }

    /// A click in the middle of `view`, or at `local` in it.
    func click(_ view: NSView, at local: NSPoint? = nil) async {
        await click(at: view.convert(local ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
    }

    /// A click at a point in the window: over once the button is back up.
    func click(at point: NSPoint) async {
        // The up goes in the queue first, for the tracking loop the down starts.
        NSApp.postEvent(mouse(.leftMouseUp, at: point), atStart: false)
        NSApp.sendEvent(mouse(.leftMouseDown, at: point))
        // A view with no tracking loop of its own leaves the up for the
        // app to hand out: nobody types before letting go of the mouse.
        await until("the click's release") {
            NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false) == nil
        }
    }

    /// A right click at a point in the window.
    func rightClick(at point: NSPoint) {
        NSApp.sendEvent(mouse(.rightMouseDown, at: point))
    }

    /// Presses in the middle of `view` and drags sideways by `distance`: the
    /// drag and the release are queued for the view's own tracking loop.
    /// The press goes straight to the view: a window that isn't key keeps
    /// a first click for itself, and the test's never is.
    func drag(_ view: NSView, across distance: CGFloat) {
        let start = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for step in 1 ... 10 {
            NSApp.postEvent(mouse(.leftMouseDragged, at: NSPoint(x: start.x + distance * CGFloat(step) / 10, y: start.y)), atStart: false)
        }
        NSApp.postEvent(mouse(.leftMouseUp, at: NSPoint(x: start.x + distance, y: start.y)), atStart: false)
        view.mouseDown(with: mouse(.leftMouseDown, at: start))
    }

    /// A press and release of the mouse's middle button on `view`.
    func middleClick(_ view: NSView) {
        let center = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center)
        if let event = center.flatMap(NSEvent.init(cgEvent:)) { view.otherMouseUp(with: event) }
    }

    /// Presses on the first row and drags it down by `rows` rows: the drag
    /// and the release are queued for the table's own tracking loop.
    func drag(_ table: NSTableView, rows: CGFloat) {
        let height = table.rowHeight + table.intercellSpacing.height
        let at = { (y: CGFloat) in table.convert(NSPoint(x: 40, y: y), to: nil) }
        let start = height / 2
        for step in 1 ... 10 { NSApp.postEvent(mouse(.leftMouseDragged, at: at(start + height * rows * CGFloat(step) / 10)), atStart: false) }
        NSApp.postEvent(mouse(.leftMouseUp, at: at(start + height * rows)), atStart: false)
        table.mouseDown(with: mouse(.leftMouseDown, at: at(start)))
    }

    /// Typed one key at a time, through the window as typing is; each key
    /// handled (and the main queue's follow-up work done) before the next.
    func type(_ text: String) async {
        for character in text {
            let key = String(character)
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(keyDown(key, ignoringModifiers: key.lowercased(), modifiers: character.isUppercase ? .shift : [],
                                         code: SelfTest.keyCodes[key.lowercased()] ?? 0, type: kind))
            }
            await Task.yield()
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }
    }

    /// A shortcut, handed out the way NSApp hands one out: to the window
    /// and its views first, then to the menu bar, and only then typed.
    func key(_ character: String, modifiers: NSEvent.ModifierFlags = .command) {
        let down = keyDown(character, modifiers: modifiers, code: SelfTest.keyCodes[character.lowercased()] ?? 0)
        if window.performKeyEquivalent(with: down) || NSApp.mainMenu?.performKeyEquivalent(with: down) == true { return }
        window.sendEvent(down)
    }

    /// Where each key sits on the keyboard: menus match a shortcut by its
    /// key as well as its character.
    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\r": 36, "l": 37, "j": 38, "k": 40, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "\t": 48, backTab: 48, " ": 49, "\u{7f}": 51, "\u{1b}": 53, upArrow: 126, downArrow: 125,
    ]

    /// A key that goes through NSApp itself, where macOS would take it for
    /// its own (⇧⌘/ searches the Help menu).
    func appKey(_ characters: String, ignoringModifiers: String, modifiers: NSEvent.ModifierFlags, code: UInt16) {
        NSApp.sendEvent(keyDown(characters, ignoringModifiers: ignoringModifiers, modifiers: modifiers, code: code))
    }

    /// Keys for whatever menu is open, queued for its tracking loop: down
    /// to the item at `index`, then Return, as someone can from the keyboard.
    static func choose(itemAt index: Int) {
        let keys = Array(repeating: (downArrow, UInt16(125)), count: index + 1) + [("\r", 36)]
        for (character, code) in keys {
            NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
                                             isARepeat: false, keyCode: code)!, atStart: false)
        }
    }

    nonisolated static let upArrow = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    nonisolated static let downArrow = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    /// What Tab sends with Shift held.
    nonisolated static let backTab = String(Character(UnicodeScalar(NSBackTabCharacter)!))

    /// Escape, into the dialog in front, as the window hands it on.
    func escape() {
        guard let sheet = window.attachedSheet else { return }
        sheet.sendEvent(keyDown("\u{1b}", code: 53, in: sheet))
    }

    /// Return, in the dialog in front. AppKit gives Return to a window's
    /// default button only while the window is key, which needs Browser to be
    /// the active app; so this checks that `title` is that button, and presses
    /// it as Return would, whichever app is in front.
    func confirm(_ title: String) {
        let button = window.attachedSheet?.defaultButtonCell
        check("Return is \(title)", button?.title == title, "default=\(button?.title ?? "none")")
        button?.performClick(nil)
    }

    /// Dark pixels in a picture: a tab's title drawn, not an empty frame.
    func ink(_ image: NSImage?) -> Int {
        guard let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let pixels = NSBitmapImageRep(cgImage: picture)
        return stride(from: 0, to: pixels.pixelsWide, by: 2).reduce(0) { sum, x in
            sum + stride(from: 0, to: pixels.pixelsHigh, by: 2).filter { y in
                pixels.colorAt(x: x, y: y).map { $0.alphaComponent > 0.5 && $0.brightnessComponent < 0.5 } == true
            }.count
        }
    }

    /// The field editor typing into `field`, if it has the keyboard.
    func editor(of field: NSTextField) -> NSTextView? {
        guard let editor = window.firstResponder as? NSTextView, editor.delegate === field else { return nil }
        return editor
    }

    /// Every view of one kind inside `view`, itself included.
    func views<Kind: NSView>(_ kind: Kind.Type, in view: NSView) -> [Kind] {
        ((view as? Kind).map { [$0] } ?? []) + view.subviews.flatMap { views(kind, in: $0) }
    }
}
#endif
