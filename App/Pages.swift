import AppKit
import CoreKit
import SwiftUI

/// Core's own pages, as native views in the tab: about://settings,
/// about://history and about://help.
@MainActor
enum Pages {
    static func view(_ page: String, open: @escaping (URL) -> Void) -> AnyView {
        switch page {
        case "settings": AnyView(SettingsPage())
        case "help": AnyView(HelpPage())
        default: AnyView(HistoryPage(open: open))
        }
    }
}

extension Pages {
    /// Side margins that keep a page's content 720 points wide at most,
    /// with its scroll bar still at the window's edge.
    static func margin(_ width: CGFloat) -> CGFloat { max(24, (width - 720) / 2) }
}

extension View {
    func readableWidth() -> some View {
        GeometryReader { geometry in
            contentMargins(.horizontal, Pages.margin(geometry.size.width), for: .scrollContent)
        }
    }
}

// MARK: History

@MainActor
final class HistoryModel: ObservableObject {
    static let shared = HistoryModel()
    @Published var query = "" { didSet { refresh() } }
    @Published private(set) var results: [History.Visit] = []

    func refresh() { results = History.shared.search(query) }
}

struct HistoryPage: View {
    let open: (URL) -> Void
    @ObservedObject private var model = HistoryModel.shared
    @State private var confirmingClear = false

    var body: some View {
        GeometryReader { geometry in
            let margin = Pages.margin(geometry.size.width)
            VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(text: $model.query, placeholder: "Search History") {
                    if let first = model.results.first, let url = URL(string: first.url) { open(url) }
                }
                .controlSize(.large)
                Button("Clear History") { confirmingClear = true }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, margin + 16)
            .padding(.vertical, 16)
            if model.results.isEmpty {
                ContentUnavailableView(model.query.isEmpty ? "No History" : "No Results", systemImage: model.query.isEmpty ? "clock" : "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.results, id: \.url) { visit in
                            HistoryRow(visit: visit, open: open)
                            Divider()
                        }
                    }
                }
                .contentMargins(.horizontal, margin + 16, for: .scrollContent)
            }
            }
        }
        .onAppear { model.refresh() }
        .alert("Clear all history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) {
                History.shared.clear()
                model.refresh()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct HistoryRow: View {
    let visit: History.Visit
    let open: (URL) -> Void
    @State private var hovering = false

    var body: some View {
        let bare = History.bare(visit.url)
        HStack(spacing: 10) {
            SiteIcon(url: URL(string: visit.url))
            VStack(alignment: .leading, spacing: 1) {
                Text(visit.title.isEmpty ? bare : visit.title).lineLimit(1)
                Text(bare).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Remove") {
                History.shared.remove(visit.url)
                HistoryModel.shared.refresh()
            }
            .buttonBorderShape(.capsule)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if let url = URL(string: visit.url) { open(url) } }
    }
}

struct SiteIcon: View {
    let url: URL?
    @State private var version = 0

    var body: some View {
        Group {
            if let icon = Favicons.shared.icon(for: url) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .id(version)
        .onAppear { if let url { Favicons.shared.fetch(site: url) } }
        .onReceive(NotificationCenter.default.publisher(for: Favicons.changed)) { _ in version += 1 }
    }
}

/// The address field's own control, AppKit's search field, for searching
/// a page of Core's.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .large
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            MainActor.assumeIsolated { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            MainActor.assumeIsolated { parent.onSubmit() }
            return true
        }
    }
}

// MARK: Settings

/// The search engines offered with one click; their icons ship with Core.
struct SearchEngine: Identifiable {
    let name: String
    let template: String
    let icon: String
    var id: String { name }

    static let all = [
        SearchEngine(name: "Google", template: "https://www.google.com/search?q=%s", icon: "google.png"),
        SearchEngine(name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s", icon: "duckduckgo.png"),
        SearchEngine(name: "Brave", template: "https://search.brave.com/search?q=%s", icon: "brave.svg"),
        SearchEngine(name: "Startpage", template: "https://www.startpage.com/do/search?query=%s", icon: "startpage.png"),
        SearchEngine(name: "Kagi", template: "https://kagi.com/search?q=%s", icon: "kagi.png"),
    ]

    @MainActor func choose() { Preferences.shared.settings.searchTemplate = template }

    var image: NSImage? {
        Bundle.main.url(forResource: icon, withExtension: nil, subdirectory: "Engines").flatMap(NSImage.init(contentsOf:))
    }
}

struct SettingsPage: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var link = ""
    @State private var installing = false
    @State private var rules = Blocker.shared.ruleCount
    @State private var trouble: String?
    @State private var installed = Extensions.shared.installed
    @State private var confirmingDefaults = false
    @State private var confirmingDefaultImage = false
    @State private var removing: Extensions.Installed?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Search Engine") {
                TextField("Search URL", text: $prefs.settings.searchTemplate, prompt: Text("https://example.com/search?q=%s"))
                    .labelsHidden()
                HStack {
                    ForEach(SearchEngine.all) { engine in
                        Button(action: engine.choose) {
                            Label {
                                Text(engine.name)
                            } icon: {
                                if let image = engine.image {
                                    Image(nsImage: image).resizable().frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                                }
                            }
                        }
                        .buttonBorderShape(.capsule)
                    }
                }
            }

            Section("New Tabs Open") {
                Picker("New Tabs Open", selection: $prefs.settings.newTabPosition) {
                    Text("Below Current Tab").tag(Settings.TabPosition.below)
                    Text("At the Top").tag(Settings.TabPosition.top)
                    Text("At the Bottom").tag(Settings.TabPosition.bottom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("New Tab Page") {
                Picker("New Tab Page", selection: $prefs.settings.newTabPage) {
                    Text("Image").tag(Settings.NewTabPage.image)
                    Text("Color").tag(Settings.NewTabPage.color)
                    Text("Blank").tag(Settings.NewTabPage.blank)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch prefs.settings.newTabPage {
                case .image:
                    HStack(spacing: 12) {
                        NewTabThumbnail(version: prefs.newTabImageVersion)
                        Button("Choose Image…", action: chooseImage).buttonBorderShape(.capsule)
                        if FileManager.default.fileExists(atPath: Settings.newTabImage.path) {
                            Button("Use Default") { confirmingDefaultImage = true }.buttonBorderShape(.capsule)
                        }
                    }
                case .color:
                    ColorPicker("Color", selection: Binding(
                        get: { Color(nsColor: NSColor(hex: prefs.settings.newTabColor)) },
                        set: { prefs.settings.newTabColor = NSColor($0).hex }
                    ), supportsOpacity: false)
                case .blank:
                    EmptyView()
                }
                Toggle("Fill Behind Sidebar", isOn: $prefs.settings.fill)
            }

            Section("Keep Cookies For") {
                RowList(items: prefs.settings.whitelist, placeholder: "Add domain", icon: { URL(string: "https://\($0)") },
                        removal: { "Delete the cookies and data kept for \($0)?" },
                        normalise: { Whitelist.normalise([$0]).first }) { prefs.settings.whitelist = $0 }
            }

            Section("Filter Lists") {
                RowList(items: prefs.settings.filterLists, placeholder: "Add filter list URL", icon: { URL(string: $0) },
                        removal: { "Remove \($0)?" },
                        normalise: { URL(string: $0)?.scheme == "https" ? $0 : nil }) {
                    prefs.settings.filterLists = $0
                    Blocker.shared.refresh(force: true)
                }
                HStack {
                    Button("Update Now") { Blocker.shared.refresh(force: true) }.buttonBorderShape(.capsule)
                    Button("Defaults") { confirmingDefaults = true }.buttonBorderShape(.capsule)
                    Spacer()
                    if rules > 0 { Text("\(rules.formatted()) rules").foregroundStyle(.secondary) }
                }
            }

            Section("Extensions") {
                HStack {
                    TextField("Chrome Web Store link or ID", text: $link).labelsHidden().onSubmit(install)
                    Button(installing ? "Installing…" : "Install", action: install)
                        .buttonBorderShape(.capsule)
                        .disabled(installing || link.isEmpty)
                    Button("Folder…", action: installFolder).buttonBorderShape(.capsule)
                }
                ForEach(installed, id: \.id) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Button("Remove") { removing = item }.buttonBorderShape(.capsule)
                    }
                }
            }

            if let trouble {
                Text(trouble).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .readableWidth()
        .onAppear(perform: load)
        .onReceive(tick) { _ in
            rules = Blocker.shared.ruleCount
            trouble = Blocker.shared.trouble ?? Extensions.shared.trouble
        }
        .alert("Replace your filter lists with the defaults?", isPresented: $confirmingDefaults) {
            Button("Replace", role: .destructive) {
                prefs.settings.filterLists = Settings.defaultFilterLists
                Blocker.shared.refresh(force: true)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Go back to the default image?", isPresented: $confirmingDefaultImage) {
            Button("Use Default") {
                try? FileManager.default.removeItem(at: Settings.newTabImage)
                prefs.newTabImageChanged()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Remove \(removing?.name ?? "this extension")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Remove", role: .destructive) {
                guard let item = removing else { return }
                Task {
                    await Extensions.shared.remove(item.id)
                    installed = Extensions.shared.installed
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its data, such as a password vault, is deleted with it.")
        }
    }

    private func load() {
        installed = Extensions.shared.installed
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        try? FileManager.default.removeItem(at: Settings.newTabImage)
        try? FileManager.default.copyItem(at: picked, to: Settings.newTabImage)
        prefs.settings.newTabPage = .image
        prefs.newTabImageChanged()
    }

    private func install() {
        guard !link.isEmpty else { return }
        installing = true
        Task {
            await Extensions.shared.install(from: link)
            installing = false
            installed = Extensions.shared.installed
            trouble = Extensions.shared.trouble
            if trouble == nil { link = "" }
        }
    }

    private func installFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            await Extensions.shared.installFolder(folder)
            installed = Extensions.shared.installed
            trouble = Extensions.shared.trouble
        }
    }
}

/// A list edited a row at a time: each row with its site's icon and a ✕
/// that shows on hover; the last row is where a new one is typed. Taking a
/// row away asks first.
struct RowList: View {
    let items: [String]
    let placeholder: String
    let icon: (String) -> URL?
    let removal: (String) -> String
    let normalise: (String) -> String?
    let save: ([String]) -> Void
    @State private var adding = ""
    @State private var removing: String?
    @State private var hovered: String?

    var body: some View {
        ForEach(items, id: \.self) { item in
            HStack(spacing: 10) {
                SiteIcon(url: icon(item))
                Text(item).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    removing = item
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(hovered == item ? 1 : 0)
                .help("Remove")
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        }
        HStack(spacing: 10) {
            Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 16)
            // In a form, a field's title is a label beside it; the prompt is
            // the text inside it, which is what this row wants.
            TextField("", text: $adding, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit(add)
        }
        .alert(removing.map(removal) ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let item = removing { save(items.filter { $0 != item }) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        }
    }

    private func add() {
        let text = adding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = normalise(text), !items.contains(item) else { return }
        save(items + [item])
        adding = ""
    }
}

struct NewTabThumbnail: View {
    let version: Int

    var body: some View {
        Group {
            if let url = Settings.newTabImageInUse, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.1)
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .id(version)
    }
}

extension NSColor {
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

// MARK: Help

struct HelpPage: View {
    private let rows = NSApp.mainMenu.map(Menus.shortcuts(in:)) ?? []

    /// Core's own pages: typed into the address field, or by their keys.
    static let pages = [
        ("History", "about://history", "⌘H"),
        ("Settings", "about://settings", "⌘,"),
        ("Help", "about://help", "⇧⌘/"),
    ]

    /// A shortcut's keys as keycaps; "A or B" is two.
    struct Keys: View {
        let text: String
        var body: some View {
            HStack(spacing: 4) {
                ForEach(text.components(separatedBy: " or "), id: \.self) { keys in
                    Text(keys)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    var body: some View {
        let sections = rows.reduce(into: [(String, [[String]])]()) { groups, row in
            if groups.last?.0 == row[0] { groups[groups.count - 1].1.append(row) } else { groups.append((row[0], [row])) }
        }
        Form {
            Section("Core Pages") {
                ForEach(HelpPage.pages, id: \.0) { page in
                    LabeledContent(page.0) {
                        HStack(spacing: 10) {
                            Text(page.1)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Keys(text: page.2)
                        }
                    }
                }
            }
            ForEach(sections, id: \.0) { section in
                Section(section.0) {
                    ForEach(section.1, id: \.self) { row in
                        LabeledContent(row[1]) { Keys(text: row[2]) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .readableWidth()
    }
}
