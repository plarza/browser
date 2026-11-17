import AppKit
import BrowserKit
import SwiftUI
import UniformTypeIdentifiers

/// What about://userscripts is showing: the script picked, and edits not
/// yet saved.
@MainActor @Observable
final class UserscriptsModel {
    static let shared = UserscriptsModel()
    var selected: String?
    /// Unsaved text per script; kept while you look at another.
    var drafts: [String: String] = [:]
    var errors: [String: String] = [:]
    /// What the last import did, under the list's header.
    private(set) var importReport: String?

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

    /// The editor's ⌘S. A script JavaScriptCore can't parse isn't saved,
    /// and says why.
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

    func remove(_ script: Userscript) {
        Task {
            guard await Dialogs.ask("Remove “\(script.name)”?", detail: "Its code and saved values will be deleted.", yes: "Remove") else { return }
            drafts[script.id] = nil
            Userscripts.shared.remove(script.id)
        }
    }
}

/// about://userscripts: the scripts down the left, each with its switch;
/// the one picked, as code, on the right.
struct UserscriptsPage: View {
    private let model = UserscriptsModel.shared

    var body: some View {
        let scripts = Userscripts.shared.scripts
        if scripts.isEmpty {
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
                list(scripts).frame(width: 240)
                Divider()
                if let script = current {
                    ScriptEditor(script: script).id(script.id)
                } else {
                    Spacer()
                }
            }
            .onAppear(perform: pickFirst)
            .onChange(of: scripts.map(\.id)) { pickFirst() }
        }
    }

    private var current: Userscript? { model.selected.flatMap { Userscripts.shared.script($0) } }

    private func list(_ scripts: [Userscript]) -> some View {
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
                    ForEach(scripts) { script in
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

    /// Something is always picked while there is anything to pick.
    private func pickFirst() {
        if current == nil { model.selected = Userscripts.shared.scripts.first?.id }
    }
}

/// A script in the list: its switch, its name and its sites, and a dot
/// while it has edits not yet saved.
private struct ScriptRow: View {
    let script: Userscript
    let selected: Bool
    let edited: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { script.enabled }, set: { Userscripts.shared.setEnabled(script.id, $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(script.name).lineLimit(1)
                Text(script.meta.sites).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

/// One script: its name and what it does, its code, Save, Revert and Remove.
private struct ScriptEditor: View {
    let script: Userscript
    private let model = UserscriptsModel.shared

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
                Button("Remove") { model.remove(script) }
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
