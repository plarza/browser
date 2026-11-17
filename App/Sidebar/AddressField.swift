import AppKit
import BrowserKit

/// The one field: AppKit's search field, as Safari's is. It shows the host
/// while you're not editing, and the whole address, all selected, when you
/// click in or press ⌘L.
@MainActor
final class AddressField: NSSearchField, NSSearchFieldDelegate {
    var onSubmit: (String) -> Void = { _ in }
    var onEscape: () -> Void = {}
    private(set) var isEditing = false
    /// Pages from History, under the field while typing. The sidebar lays it out.
    let suggestions = SuggestionList()

    private var url: URL?
    private var following: Observer?
    private var flashing: Task<Void, Never>?
    /// The clear button, shown only while editing, as in Safari.
    private var clear: NSButtonCell?
    /// The last edit removed text: don't fill it straight back in.
    private var deleting = false
    /// What was typed, without the filled-in part.
    private var typed = ""
    /// The History lookup for the latest keystroke.
    private var lookup: Task<Void, Never>?
    private static let placeholder = "Search or enter website name"

    init(browser: Browser) {
        super.init(frame: .zero)
        controlSize = .large
        font = .systemFont(ofSize: 13)
        placeholderString = AddressField.placeholder
        sendsWholeSearchString = true
        lineBreakMode = .byTruncatingTail
        delegate = self
        clear = (cell as? NSSearchFieldCell)?.cancelButtonCell
        suggestions.onPick = { [weak self] visit in
            guard let self else { return }
            History.shared.picked(visit.url, after: typed)
            suggestions.hide()
            onSubmit(visit.url)
        }
        following = Observer { [weak self] in self?.show(browser.selected?.url) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func showClear(_ shown: Bool) {
        (cell as? NSSearchFieldCell)?.cancelButtonCell = shown ? clear : nil
        needsDisplay = true
    }

    // The text goes in before focus does: changing a field's text while it
    // is being edited ends the editing.
    override func becomeFirstResponder() -> Bool {
        beginEditing()
        guard super.becomeFirstResponder() else { return false }
        quietEditor()
        selectEverything()
        return true
    }

    /// A click or ⌘L: the whole address, https and all, selected.
    func focus() {
        beginEditing()
        if currentEditor() == nil { window?.makeFirstResponder(self) }
        selectEverything()
    }

    /// The system's own grey word predictions would fight the fill-in.
    private func quietEditor() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.inlinePredictionType = .no
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
    }

    private func selectEverything() {
        guard let editor = currentEditor() as? NSTextView else { return }
        if editor.string != stringValue { editor.string = stringValue }
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
    }

    /// The address of the page showing; it waits while the field is being
    /// typed in.
    private func show(_ url: URL?) {
        self.url = url
        guard !isEditing else { return }
        stringValue = url.map(AddressField.display) ?? ""
        alignment = .center
        showClear(false)
    }

    /// An address as the field and the tabs show it at rest: the site's
    /// name without `www.`, a file's path, or one of Browser's own pages.
    static func display(_ url: URL) -> String {
        if url.scheme == "about" { return url.absoluteString }
        if url.isFileURL { return (url.path as NSString).abbreviatingWithTildeInPath }
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        alignment = .left
        showClear(true)
        stringValue = url?.absoluteString ?? ""
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditing = false
        lookup?.cancel()
        suggestions.hide()
        show(url)
    }

    /// As you type: the rest of a site's name filled in and selected, so
    /// typing on replaces it and Delete removes it; and the best pages from
    /// History listed underneath.
    func controlTextDidChange(_ obj: Notification) {
        guard let editor = currentEditor() as? NSTextView else { return }
        let typed = editor.string
        self.typed = typed
        let wasDeleting = deleting
        deleting = false
        // History answers off the main thread; an answer for text that has
        // since changed is dropped. It also lands after AppKit has finished
        // with the keystroke: before that, the text system puts the caret
        // back after the typed character and the filled-in part ends up
        // unselected.
        lookup?.cancel()
        lookup = Task { [weak self, weak editor] in
            let found = await History.shared.complete(typed)
            guard !Task.isCancelled, let self, let editor, currentEditor() === editor, editor.string == typed else { return }
            suggestions.show(found.pages)
            guard !wasDeleting,
                  editor.selectedRange() == NSRange(location: (typed as NSString).length, length: 0),
                  let fill = found.fill, fill.lowercased().hasPrefix(typed.lowercased())
            else { return }
            let rest = String(fill.dropFirst(typed.count))
            let start = (typed as NSString).length
            editor.textStorage?.replaceCharacters(in: NSRange(location: start, length: 0), with: rest)
            editor.setSelectedRange(NSRange(location: start, length: (rest as NSString).length))
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = suggestions.selected?.url ?? textView.string
            if let picked = suggestions.selected { History.shared.picked(picked.url, after: typed) }
            suggestions.hide()
            onSubmit(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if suggestions.isShown { suggestions.hide() } else { onEscape() }
            return true
        case #selector(NSResponder.moveDown(_:)):
            return suggestions.move(1)
        case #selector(NSResponder.moveUp(_:)):
            return suggestions.move(-1)
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
             #selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteToBeginningOfLine(_:)):
            deleting = true
            return false
        default:
            return false
        }
    }

    /// A word to the person typing, where the placeholder is, for a moment.
    func flash(_ message: String) {
        flashing?.cancel()
        let typed = stringValue
        stringValue = ""
        placeholderString = message
        focus()
        flashing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            placeholderString = AddressField.placeholder
            if stringValue.isEmpty { stringValue = typed }
        }
    }
}
