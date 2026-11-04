import AppKit
import BrowserKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: about://userscripts

/// What the page is showing: the script picked, and edits not yet saved.
@MainActor
final class UserscriptsModel: ObservableObject {
    static let shared = UserscriptsModel()
    @Published var selected: String?
    /// Unsaved text per script; kept while you look at another.
    @Published var drafts: [String: String] = [:]
    @Published var errors: [String: String] = [:]
    /// What the last import did, under the list's header.
    @Published var importReport: String?

    /// Violentmonkey's backup .zip, or .user.js files.
    func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .javaScript]
        panel.message = "Choose Violentmonkey's backup (.zip) or .user.js files."
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func importFiles(_ urls: [URL]) {
        importReport = "Importing…"
        Task {
            let (count, problems) = await Userscripts.shared.importFiles(urls)
            var report = count == 1 ? "Imported 1 script." : "Imported \(count) scripts."
            if !problems.isEmpty { report += " Not imported: " + problems.joined(separator: "; ") }
            importReport = report
            if selected == nil { selected = Userscripts.shared.scripts.first?.id }
        }
    }

    func text(_ script: Userscript) -> String { drafts[script.id] ?? script.source }
    func isEdited(_ script: Userscript) -> Bool { drafts[script.id].map { $0 != script.source } ?? false }

    func save(_ id: String) {
        guard let draft = drafts[id] else { return }
        Task {
            do {
                try await Userscripts.shared.save(id, source: draft)
                if drafts[id] == draft { drafts[id] = nil }
                errors[id] = nil
            } catch {
                errors[id] = error.localizedDescription
            }
        }
    }

    func revert(_ id: String) {
        drafts[id] = nil
        errors[id] = nil
    }
}

/// Scripts down the left, each with its switch; the one picked, as code,
/// on the right.
struct UserscriptsPage: View {
    @ObservedObject private var scripts = Userscripts.shared
    @ObservedObject private var model = UserscriptsModel.shared

    var body: some View {
        if scripts.scripts.isEmpty {
            ContentUnavailableView {
                Label("No Userscripts", systemImage: "curlybraces")
            } description: {
                Text("Open a .user.js link or file to install one.")
            } actions: {
                HStack {
                    Button("New Script", action: create).buttonBorderShape(.capsule)
                    Button("Import…") { model.chooseImport() }.buttonBorderShape(.capsule)
                }
                if let report = model.importReport { Text(report).font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            HStack(spacing: 0) {
                list.frame(width: 240)
                Divider()
                if let script = current {
                    ScriptEditor(script: script).id(script.id)
                } else {
                    Spacer()
                }
            }
            .onAppear(perform: pickFirst)
            .onChange(of: scripts.scripts.map(\.id)) { pickFirst() }
        }
    }

    private var current: Userscript? { model.selected.flatMap { Userscripts.shared.script($0) } }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Import…") { model.chooseImport() }.buttonBorderShape(.capsule)
                Button("New", action: create).buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)
            if let report = model.importReport {
                Text(report)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .textSelection(.enabled)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(scripts.scripts) { script in
                        ScriptRow(script: script, selected: script.id == model.selected, edited: model.isEdited(script))
                            .onTapGesture { model.selected = script.id }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private func create() {
        model.selected = Userscripts.shared.create().id
    }

    private func pickFirst() {
        if current == nil { model.selected = scripts.scripts.first?.id }
    }
}

struct ScriptRow: View {
    let script: Userscript
    let selected: Bool
    let edited: Bool

    var body: some View {
        let meta = script.meta
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { script.enabled }, set: { Userscripts.shared.setEnabled(script.id, $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(script.name).lineLimit(1)
                Text(meta.sites).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if edited {
                Circle().fill(.secondary).frame(width: 6, height: 6).help("Not saved")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

/// One script: its name and what it does, its code, Save and Revert.
struct ScriptEditor: View {
    let script: Userscript
    @ObservedObject private var model = UserscriptsModel.shared

    var body: some View {
        let meta = script.meta
        let edited = model.isEdited(script)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(script.name).font(.headline).lineLimit(1)
                    Text([meta.version, meta.sites].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if edited { Text("Edited").font(.caption).foregroundStyle(.secondary) }
                Button("Revert") { model.revert(script.id) }
                    .buttonBorderShape(.capsule)
                    .disabled(!edited)
                Button("Save") { model.save(script.id) }
                    .buttonBorderShape(.capsule)
                    .buttonStyle(.borderedProminent)
                    .disabled(!edited)
                    .help("Save (⌘S)")
                Button("Remove") {
                    Task {
                        guard await Dialogs.ask("Remove “\(script.name)”?", detail: "Its code and saved values will be deleted.", yes: "Remove") else { return }
                        model.drafts[script.id] = nil
                        Userscripts.shared.remove(script.id)
                    }
                }
                .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if let error = model.errors[script.id] {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .textSelection(.enabled)
            }
            Divider()
            CodeEditor(text: Binding(get: { model.text(script) }, set: { model.drafts[script.id] = $0 }),
                       onSave: { model.save(script.id) })
        }
    }
}

// MARK: Editor

/// The editor's text view: ⌘S saves while it has the keyboard (the window
/// asks it before the menu's ⌘S, which hides the sidebar).
final class CodeTextView: NSTextView {
    var onSave: (() -> Void)?
}

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
        private var pending: DispatchWorkItem?
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            parent.text = view.string
            pending?.cancel()
            let work = DispatchWorkItem { [weak view] in
                MainActor.assumeIsolated { if let view { Highlighter.apply(to: view) } }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
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
    private static let meta = try! NSRegularExpression(pattern: #"^\s*//\s*(@[\w:.-]+)"#, options: [.anchorsMatchLines])

    static func apply(to view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let text = storage.string
        let all = NSRange(location: 0, length: (text as NSString).length)
        let colours: [NSColor] = [.secondaryLabelColor, .systemRed, .systemPink, .systemBlue]
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

// MARK: Install bar

/// Over a .user.js file the tab shows as text: the script's name, where it
/// runs, and Install.
@MainActor
final class InstallBar: NSView {
    static let height: CGFloat = 52
    let button = NSButton(title: "Install", target: nil, action: nil)
    var onButton: () -> Void = {}
    private let icon = NSImageView(image: NSImage(systemSymbolName: "curlybraces", accessibilityDescription: nil)!)
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        button.bezelStyle = .push
        button.controlSize = .large
        button.target = self
        button.action = #selector(clicked)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text, NSView(), button])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(line)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }

    func show(title: String, detail: String, button label: String, enabled: Bool, prominent: Bool) {
        self.title.stringValue = title
        self.detail.stringValue = detail
        button.title = label
        button.isEnabled = enabled
        button.bezelColor = prominent ? .controlAccentColor : nil
    }

    @objc private func clicked() { onButton() }

    var detailText: String { detail.stringValue }
}
