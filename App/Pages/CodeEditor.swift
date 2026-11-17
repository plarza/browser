import AppKit
import SwiftUI

/// The editor's text view: ⌘S saves while it has the keyboard (the window
/// asks it before the menu's ⌘S, which hides the sidebar).
final class CodeTextView: NSTextView {
    var onSave: (() -> Void)?
}

/// A script's code: one font, JavaScript's colours, lines that don't wrap,
/// and the text system's own find bar.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let onSave: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = CodeTextView(frame: .zero)
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.font = Highlighter.font
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 10, height: 10)
        // Lines don't wrap: code scrolls sideways.
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.string = text
        view.onSave = onSave
        Highlighter.apply(to: view)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? CodeTextView else { return }
        view.onSave = onSave
        if view.string != text {
            view.string = text
            Highlighter.apply(to: view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        /// The colours catch up a moment after the typing stops.
        private var colouring: Task<Void, Never>?
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            parent.text = view.string
            colouring?.cancel()
            colouring = Task { [weak view] in
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled, let view { Highlighter.apply(to: view) }
            }
        }
    }
}

/// JavaScript's colours, in one pass so a `//` in a string stays a string.
@MainActor
enum Highlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let pattern = try! NSRegularExpression(pattern: #"""
    (//[^\n]*|/\*[\s\S]*?\*/)|("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`)|\b(const|let|var|function|return|if|else|for|while|do|switch|case|break|continue|new|class|extends|import|export|from|async|await|try|catch|finally|throw|typeof|instanceof|in|of|this|null|undefined|true|false|yield|delete|void|default|static|get|set)\b|\b(\d+(?:\.\d+)?)\b
    """#)
    /// The metadata block's keys: `// @name`, `// @match`.
    private static let meta = try! NSRegularExpression(pattern: #"^\s*//\s*(@[\w:.-]+)"#, options: [.anchorsMatchLines])
    /// Comments, strings, keywords and numbers, in the pattern's order.
    private static let colours: [NSColor] = [.secondaryLabelColor, .systemRed, .systemPink, .systemBlue]

    static func apply(to view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let text = storage.string
        let all = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: all)
        for match in pattern.matches(in: text, range: all) {
            for group in 1 ... 4 where match.range(at: group).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: colours[group - 1], range: match.range(at: group))
            }
        }
        for match in meta.matches(in: text, range: all) {
            storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: match.range(at: 1))
        }
        storage.endEditing()
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
    }
}
